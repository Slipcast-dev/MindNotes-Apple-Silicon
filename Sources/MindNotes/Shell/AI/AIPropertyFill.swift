import AppKit
import SwiftUI

/// ИИ-заполнение свойств базы (FR-AI-8). Настройка — в `config.extra["ai"]` свойства, значения — обычные значения
/// его типа: фильтры, сортировка, поиск и CSV работают без сети. Отметка «создано ИИ» — отпечаток значения
/// в `workspace_meta`: ручная правка меняет значение, и ячейка перестаёт считаться ячейкой ИИ.
@MainActor
final class AIPropertyFiller: ObservableObject {
    static let shared = AIPropertyFiller()

    struct Progress: Equatable {
        var done = 0
        var total = 0
        var failed = 0
        /// Пакет отправлен: результат придёт позже (до 24 ч).
        var batch = false
    }

    /// Последнее заполнение свойства: для «Отменить заполнение».
    struct Run {
        var database: UUID
        var old: [(page: UUID, value: PropertyValue?)]
        var marks: [UUID: String]
    }

    /// Пакет Batches в работе: переживает перезапуск (ключ `workspace_meta`).
    struct PendingBatch: Codable, Equatable {
        var batch: String
        var property: UUID
        var database: UUID
        var scope: String
    }

    static let parallel = 3
    static let maxRecords = 5_000
    /// Больше этого числа записей предлагается пакетная обработка.
    static let batchThreshold = 50
    private static let batchesKey = "ai_batches"

    @Published private(set) var progress: [UUID: Progress] = [:]
    @Published private(set) var lastRun: [UUID: Run] = [:]
    @Published private(set) var marks: [UUID: [UUID: String]] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var pending: [PendingBatch] = []
    private var poller: Task<Void, Never>?
    private var autoTimers: [UUID: Task<Void, Never>] = [:]
    private weak var shell: ShellModel?

    func isRunning(_ property: UUID) -> Bool { tasks[property] != nil || pending.contains { $0.property == property } }

    // MARK: Настройка

    func setConfig(_ config: AIPropertyConfig?, property: PropertyDefinition, model: DatabaseModel) {
        model.perform { [store = model.store] in try await store.setPropertyExtra(property.id, key: AIPropertyConfig.key, value: config?.json) }
    }

    func stop(_ property: UUID) { tasks[property]?.cancel() }

    private var loadingMarks: Set<UUID> = []

    /// Отметки для значков в ячейках: читаются один раз на свойство, сколько бы ячеек ни спросило.
    func ensureMarks(_ property: UUID, store: SQLiteWorkspace) async {
        guard marks[property] == nil, loadingMarks.insert(property).inserted else { return }
        defer { loadingMarks.remove(property) }
        _ = await loadMarks(property, store: store)
    }

    func loadMarks(_ property: UUID, store: SQLiteWorkspace) async -> [UUID: String] {
        let loaded = AIValues.decodeMarks(try? await store.meta(AIValues.marksKey(property)))
        marks[property] = loaded
        return loaded
    }

    private func saveMarks(_ property: UUID, _ value: [UUID: String], store: SQLiteWorkspace) async {
        marks[property] = value
        try? await store.setMeta(AIValues.marksKey(property), AIValues.encodeMarks(value))
    }

    /// Сколько ячеек сейчас «создано ИИ».
    func aiOwnedCount(_ property: PropertyDefinition, rows: [RecordRow]) -> Int {
        guard let m = marks[property.id] else { return 0 }
        return rows.filter { row in m[row.id].map { $0 == AIValues.fingerprint(row.values[property.id]) } ?? false }.count
    }

    // MARK: Запрос на одну запись

    private func params(for row: RecordRow, config: AIPropertyConfig, property: PropertyDefinition, database: Database, shell: ShellModel, stream: Bool) async -> JSONValue {
        let blocks = (try? await shell.aiBlocks(of: row.id)) ?? []
        let body = blocks.filter { $0.content != nil }.map(\.plainText).joined(separator: "\n")
        let others = database.properties.filter { $0.type != .title && $0.id != property.id }
            .map { (name: $0.name, value: PropertyDisplay.text(row.values[$0.id], property: $0) ?? "") }
        let request = config.request(title: row.title, properties: others, body: body, target: property)
        return AIRequest.body(model: AISettings.shared.model, system: AIPropertyConfig.system, messages: [AIRequest.userText(request)],
                              effort: .low, stream: stream, maxTokens: 2_048,
                              format: AIValues.format(for: property, allowNew: config.createsOptions(property)), fallbacks: stream)
    }

    /// Ответ модели в значение свойства; nil — ответа нет или он не подходит к типу.
    /// С `creator` у выбора недостающие варианты создаются (в пределах заполнения).
    private func value(from turn: AIAssistantTurn?, property: PropertyDefinition, creator: AIOptionCreator?) async -> PropertyValue?? {
        guard let turn, turn.stopReason == "end_turn" else { return .none }
        AISettings.shared.record(turn.usage)
        let json = JSONValue.parse(turn.text.trimmingCharacters(in: .whitespacesAndNewlines))?["value"]
        if let creator, let names = AIValues.optionNames(from: json, property: property) {
            return .some(await creator.value(for: names))
        }
        return AIValues.value(from: json, property: property)
    }

    /// Создатель вариантов на одно заполнение; nil — свойство не выбор или новые варианты выключены.
    private func creator(for property: PropertyDefinition, config: AIPropertyConfig, store: SQLiteWorkspace) -> AIOptionCreator? {
        config.createsOptions(property) ? AIOptionCreator(property: property, store: store) : nil
    }

    // MARK: Заполнение

    /// Заполняет записи базы. `scope`: пустые; пустые и созданные ИИ (ручные правки не трогаются); все.
    func fill(property: PropertyDefinition, model: DatabaseModel, shell: ShellModel, scope: AIValues.Scope) {
        guard tasks[property.id] == nil, AIValues.fillable.contains(property.type),
              let config = AIPropertyConfig(json: property.config.extra[AIPropertyConfig.key]), let database = model.database else { return }
        self.shell = shell
        let store = model.store
        tasks[property.id] = Task { @MainActor in
            defer {
                tasks[property.id] = nil
                if progress[property.id]?.batch != true { progress[property.id] = nil }
                model.reload()
            }
            do {
                let page = try await store.queryRecords(database: database, state: DatabaseViewState(), limit: Self.maxRecords, offset: 0)
                let owned = await loadMarks(property.id, store: store)
                let rows = page.rows.filter {
                    !AIWorkspace.shared.isExcluded($0.id, shell: shell) && AIValues.shouldFill($0.values[property.id], mark: owned[$0.id], scope: scope)
                }
                guard !rows.isEmpty else {
                    shell.notice = L("Нечего заполнять: подходящих записей нет.")
                    return
                }
                // Пакеты (вдвое дешевле) есть только у Anthropic; у остальных провайдеров — сразу.
                if rows.count > Self.batchThreshold, AISettings.shared.provider.batches {
                    let alert = NSAlert()
                    alert.messageText = String(format: L("Заполнить записей: %d?"), rows.count)
                    alert.informativeText = L("Пакетом — вдвое дешевле, результат придёт позже (обычно за минуты, до 24 ч), приложение должно быть открыто. Сразу — по три запроса одновременно.")
                    alert.addButton(withTitle: L("Пакетом"))
                    alert.addButton(withTitle: L("Сразу"))
                    alert.addButton(withTitle: L("Отмена"))
                    switch alert.runModal() {
                    case .alertFirstButtonReturn:
                        try await startBatch(rows: rows, config: config, property: property, database: database, scope: scope, store: store, shell: shell)
                        return
                    case .alertSecondButtonReturn: break
                    default: return
                    }
                }
                progress[property.id] = Progress(total: rows.count)
                let optionCreator = creator(for: property, config: config, store: store)
                var written: [(page: UUID, value: PropertyValue?)] = []
                var old: [(page: UUID, value: PropertyValue?)] = []
                var start = 0
                while start < rows.count, !Task.isCancelled {
                    let chunk = Array(rows[start..<min(start + Self.parallel, rows.count)])
                    start += chunk.count
                    var values: [(page: UUID, value: PropertyValue?)] = []
                    // Ответы — параллельно; разбор и создание вариантов — по очереди, чтобы не было дублей.
                    var turns: [(UUID, AIAssistantTurn?)] = []
                    await withTaskGroup(of: (UUID, AIAssistantTurn?).self) { group in
                        for row in chunk {
                            group.addTask { @MainActor in
                                let body = await self.params(for: row, config: config, property: property, database: database, shell: shell, stream: true)
                                return (row.id, try? await AIClient.stream(body, onEvent: { _, _ in }))
                            }
                        }
                        for await item in group { turns.append(item) }
                    }
                    for (id, turn) in turns {
                        if case .some(let value) = await value(from: turn, property: property, creator: optionCreator) { values.append((id, value)) } else { progress[property.id]?.failed += 1 }
                        progress[property.id]?.done += 1
                    }
                    guard !Task.isCancelled else { break }
                    if !values.isEmpty {
                        let previous = Dictionary(uniqueKeysWithValues: chunk.map { ($0.id, $0.values[property.id]) })
                        old += values.map { ($0.page, previous[$0.page] ?? nil) }
                        try await store.setValues(property: property.id, values, now: SystemClock().nowMillis())
                        written += values
                    }
                }
                await finishRun(property: property.id, database: database.id, written: written, old: old, owned: owned, store: store)
                let failed = progress[property.id]?.failed ?? 0
                var notes: [String] = []
                if let optionCreator, optionCreator.created > 0 { notes.append(String(format: L("Новых вариантов: %d."), optionCreator.created)) }
                if let optionCreator, optionCreator.skipped > 0 { notes.append(String(format: L("Предел новых вариантов (%d) достигнут: часть значений не создана."), AIValues.maxNewOptionsPerFill)) }
                if failed > 0 { notes.append(String(format: L("ИИ не заполнил записей: %d. Попробуйте ещё раз."), failed)) }
                if !notes.isEmpty { shell.notice = notes.joined(separator: " ") }
            } catch {
                shell.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Отметки ИИ и снимок для отмены.
    private func finishRun(property: UUID, database: UUID, written: [(page: UUID, value: PropertyValue?)], old: [(page: UUID, value: PropertyValue?)],
                           owned: [UUID: String], store: SQLiteWorkspace) async {
        guard !written.isEmpty else { return }
        var next = owned
        for item in written { next[item.page] = item.value == nil ? nil : AIValues.fingerprint(item.value) }
        await saveMarks(property, next, store: store)
        let run = Run(database: database, old: old, marks: owned)
        lastRun[property] = run
        // Снимок для отмены хранится в пространстве: «Отменить заполнение» доступно и после перезапуска.
        try? await store.setMeta(AIValues.lastRunKey(property), AIValues.encodeRun(database: database, old: old, marks: owned))
    }

    /// Снимок последнего заполнения из пространства.
    func loadLastRun(_ property: PropertyDefinition, store: SQLiteWorkspace) async {
        guard lastRun[property.id] == nil, let text = try? await store.meta(AIValues.lastRunKey(property.id)),
              let run = AIValues.decodeRun(text, property: property) else { return }
        lastRun[property.id] = Run(database: run.database, old: run.old, marks: run.marks)
    }

    /// «Отменить заполнение»: прежние значения и прежние отметки. Ячейки, исправленные после заполнения, не трогаются.
    func undoLastRun(_ property: PropertyDefinition, model: DatabaseModel) {
        guard let run = lastRun[property.id] else { return }
        lastRun[property.id] = nil
        let store = model.store
        model.perform {
            try? await store.setMeta(AIValues.lastRunKey(property.id), "")
            guard let database = model.database else { return }
            let current = try await store.queryRecords(database: database, state: DatabaseViewState(), limit: Self.maxRecords, offset: 0)
            let now = Dictionary(uniqueKeysWithValues: current.rows.map { ($0.id, $0.values[property.id]) })
            // Отметки читаются заново: после перезапуска их в памяти ещё нет.
            let owned = await self.loadMarks(property.id, store: store)
            let restore = run.old.filter { item in owned[item.page] == AIValues.fingerprint(now[item.page] ?? nil) }
            if !restore.isEmpty { try await store.setValues(property: property.id, restore, now: SystemClock().nowMillis()) }
            await self.saveMarks(property.id, run.marks, store: store)
        }
    }

    // MARK: Пакеты

    private func startBatch(rows: [RecordRow], config: AIPropertyConfig, property: PropertyDefinition, database: Database,
                            scope: AIValues.Scope, store: SQLiteWorkspace, shell: ShellModel) async throws {
        var requests: [(id: String, params: JSONValue)] = []
        for row in rows {
            requests.append((row.id.uuidString.lowercased(), await params(for: row, config: config, property: property, database: database, shell: shell, stream: false)))
        }
        let id = try await AIClient.createBatch(requests)
        pending.append(PendingBatch(batch: id, property: property.id, database: database.id, scope: scope == .all ? "all" : scope == .empty ? "empty" : "ai"))
        progress[property.id] = Progress(total: rows.count, batch: true)
        try? await store.setMeta(Self.batchesKey, String(decoding: (try? JSONEncoder().encode(pending)) ?? Data("[]".utf8), as: UTF8.self))
        shell.notice = L("Пакет отправлен. Значения появятся, когда ИИ закончит; приложение должно оставаться открытым.")
        startPolling(store: store)
    }

    /// Пакеты из прошлого запуска продолжают ждаться после открытия пространства.
    func resume(store: SQLiteWorkspace, shell: ShellModel) {
        self.shell = shell
        poller?.cancel()
        pending = []
        progress = progress.filter { !$0.value.batch }
        Task { @MainActor in
            guard let text = try? await store.meta(Self.batchesKey), let list = try? JSONDecoder().decode([PendingBatch].self, from: Data(text.utf8)) else { return }
            pending = list
            for p in list { progress[p.property] = Progress(batch: true) }
            if !list.isEmpty { startPolling(store: store) }
        }
    }

    func detach() {
        poller?.cancel()
        poller = nil
        pending = []
        tasks.values.forEach { $0.cancel() }
        autoTimers.values.forEach { $0.cancel() }
        autoTimers = [:]
        progress = [:]
        lastRun = [:]
        marks = [:]
    }

    private func startPolling(store: SQLiteWorkspace) {
        guard poller == nil else { return }
        poller = Task { @MainActor in
            defer { poller = nil }
            while !pending.isEmpty, !Task.isCancelled {
                for item in pending {
                    guard AISettings.isEnabled, let status = try? await AIClient.batchStatus(item.batch), status.ended else { continue }
                    await collect(item, path: status.resultsPath, store: store)
                    pending.removeAll { $0 == item }
                    try? await store.setMeta(Self.batchesKey, String(decoding: (try? JSONEncoder().encode(pending)) ?? Data("[]".utf8), as: UTF8.self))
                }
                if pending.isEmpty { break }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func collect(_ item: PendingBatch, path: String?, store: SQLiteWorkspace) async {
        defer { progress[item.property] = nil }
        guard let path, let results = try? await AIClient.batchResults(path),
              let database = try? await store.database(item.database), let property = database.property(item.property) else {
            shell?.notice = L("Пакет ИИ завершился без результатов.")
            return
        }
        let owned = await loadMarks(property.id, store: store)
        let scope: AIValues.Scope = item.scope == "all" ? .all : item.scope == "empty" ? .empty : .aiOwned
        var written: [(page: UUID, value: PropertyValue?)] = []
        var old: [(page: UUID, value: PropertyValue?)] = []
        var failed = 0
        let optionCreator = AIPropertyConfig(json: property.config.extra[AIPropertyConfig.key]).flatMap { creator(for: property, config: $0, store: store) }
        // В пакете нет замены модели при отказе: отказанные и неудавшиеся записи повторяются обычным запросом,
        // у которого сервер сам переключается на подходящую модель (`fallbacks`).
        var retried: [String: AIAssistantTurn?] = [:]
        let needRetry = results.filter { _, turn in turn == nil || turn?.stopReason == "refusal" }.map(\.id)
        if !needRetry.isEmpty, let shell, let config = AIPropertyConfig(json: property.config.extra[AIPropertyConfig.key]) {
            for id in needRetry.prefix(200) {
                guard let page = UUID(uuidString: id), let values = try? await store.recordValues(page: page, database: database),
                      let record = shell.pages.first(where: { $0.id == page }) else { continue }
                let row = RecordRow(id: page, title: record.title, icon: record.icon, values: values)
                let body = await params(for: row, config: config, property: property, database: database, shell: shell, stream: true)
                retried[id] = try? await AIClient.stream(body, onEvent: { _, _ in })
            }
        }
        for (id, batchTurn) in results {
            guard let page = UUID(uuidString: id) else { continue }
            let turn = retried[id] ?? batchTurn
            guard case .some(let value) = await value(from: turn, property: property, creator: optionCreator) else { failed += 1; continue }
            // За время ожидания ячейку могли заполнить вручную: «пустые» и «созданные ИИ» её не трогают,
            // «Перезаписать все» перезаписывает, как и просили.
            let current = (try? await store.recordValues(page: page, database: database))?[property.id]
            guard AIValues.shouldFill(current, mark: owned[page], scope: scope) else { continue }
            written.append((page, value))
            old.append((page, current))
        }
        if !written.isEmpty { try? await store.setValues(property: property.id, written, now: SystemClock().nowMillis()) }
        await finishRun(property: property.id, database: database.id, written: written, old: old, owned: owned, store: store)
        shell?.notice = String(format: L("ИИ заполнил записей: %d."), written.count) + (failed > 0 ? " " + String(format: L("Не заполнено: %d."), failed) : "")
        shell?.databaseModel?.reload()
    }

    // MARK: Автообновление при правке записи

    /// Правка страницы записи: через 5 с тишины обновляются её ИИ-свойства с «Обновлять при изменении».
    func recordEdited(_ page: UUID, shell: ShellModel) {
        guard AISettings.isEnabled, AISettings.shared.hasKey, let record = shell.pages.first(where: { $0.id == page }), let databaseID = record.databaseID,
              let store = shell.store, !AIWorkspace.shared.isExcluded(page, shell: shell) else { return }
        autoTimers[page]?.cancel()
        autoTimers[page] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            autoTimers[page] = nil
            guard let database = try? await store.database(databaseID) else { return }
            let targets = database.properties.filter {
                AIValues.fillable.contains($0.type) && AIPropertyConfig(json: $0.config.extra[AIPropertyConfig.key])?.auto == true && tasks[$0.id] == nil
            }
            guard !targets.isEmpty, let values = try? await store.recordValues(page: page, database: database) else { return }
            let row = RecordRow(id: page, title: record.title, icon: record.icon, values: values)
            for property in targets {
                guard let config = AIPropertyConfig(json: property.config.extra[AIPropertyConfig.key]) else { continue }
                let owned = await loadMarks(property.id, store: store)
                guard AIValues.shouldFill(values[property.id], mark: owned[page], scope: .aiOwned) else { continue }
                let body = await params(for: row, config: config, property: property, database: database, shell: shell, stream: true)
                let turn = try? await AIClient.stream(body, onEvent: { _, _ in })
                guard case .some(let value) = await self.value(from: turn, property: property, creator: creator(for: property, config: config, store: store)) else { continue }
                guard value != values[property.id] else { continue }
                try? await store.setValues(property: property.id, [(page, value)], now: SystemClock().nowMillis())
                var next = owned
                next[page] = value == nil ? nil : AIValues.fingerprint(value)
                await saveMarks(property.id, next, store: store)
            }
            shell.databaseModel?.reload()
        }
    }
}

/// Строка настройки ИИ у свойства в окне «Свойства».
struct AIPropertyControls: View {
    @ObservedObject var model: DatabaseModel
    let property: PropertyDefinition
    @ObservedObject private var filler = AIPropertyFiller.shared
    @EnvironmentObject private var shell: ShellModel

    private var config: AIPropertyConfig? { AIPropertyConfig(json: property.config.extra[AIPropertyConfig.key]) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundColor(AIStyle.tint).font(.system(size: 12))
                Menu(config.map { L(AIPropertyConfig.title($0.kind)) } ?? L("ИИ выключен для свойства")) {
                    Button(L("Без ИИ")) { filler.setConfig(nil, property: property, model: model) }
                    Divider()
                    ForEach(AIPropertyConfig.Kind.available(for: property.type).filter { $0 != .custom }, id: \.self) { kind in
                        Button(L(AIPropertyConfig.title(kind))) { filler.setConfig(AIPropertyConfig(kind: kind, auto: config?.auto ?? false, newOptions: config?.newOptions ?? true), property: property, model: model) }
                    }
                    Button(L("Свой запрос…")) {
                        guard let prompt = PromptAlert.ask(L("Что ИИ должен написать в этом свойстве?"), value: config?.prompt ?? ""),
                              !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        filler.setConfig(AIPropertyConfig(kind: .custom, prompt: prompt, auto: config?.auto ?? false, newOptions: config?.newOptions ?? true), property: property, model: model)
                    }
                }
                .fixedSize()
                .font(.system(size: 12))
                if let config {
                    Toggle(L("Обновлять при изменении записи"), isOn: Binding(get: { config.auto }, set: { on in
                        var next = config
                        next.auto = on
                        filler.setConfig(next, property: property, model: model)
                    }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .help(L("Через 5 секунд после правки страницы записи ИИ обновит её значение; каждый раз — платный запрос"))
                    if property.type == .select || property.type == .multiSelect {
                        Toggle(String(format: L("Новые варианты (до %d за заполнение)"), AIValues.maxNewOptionsPerFill), isOn: Binding(get: { config.newOptions }, set: { on in
                            var next = config
                            next.newOptions = on
                            filler.setConfig(next, property: property, model: model)
                        }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .help(L("Если ни один вариант не подходит, ИИ добавит новый. Выключено — только существующие варианты."))
                    }
                }
            }
            if config != nil { actions.padding(.leading, 20) }
        }
        .task(id: property.id) {
            _ = await filler.loadMarks(property.id, store: model.store)
            await filler.loadLastRun(property, store: model.store)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if let p = filler.progress[property.id] {
                if p.batch {
                    ProgressView().controlSize(.small)
                    Text("Пакет в работе: результат придёт позже").font(.system(size: 11)).foregroundColor(Tokens.muted)
                } else {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 80)
                    Text(String(format: L("Заполняется %d из %d"), p.done, p.total)).font(.system(size: 11)).foregroundColor(Tokens.muted)
                    Button(L("Стоп")) { filler.stop(property.id) }.buttonStyle(NotesButtonStyle(kind: .plain))
                }
            } else if filler.isRunning(property.id) {
                ProgressView().controlSize(.small)
            } else {
                Button(L("Заполнить пустые")) { filler.fill(property: property, model: model, shell: shell, scope: .empty) }
                    .buttonStyle(NotesButtonStyle())
                    .disabled(!AISettings.shared.isActive)
                Button(L("Обновить созданные ИИ")) { filler.fill(property: property, model: model, shell: shell, scope: .aiOwned) }
                    .buttonStyle(NotesButtonStyle(kind: .plain))
                    .disabled(!AISettings.shared.isActive)
                    .help(L("Пустые и ранее заполненные ИИ ячейки; исправленные вручную не трогаются"))
                Button(L("Перезаписать все…")) {
                    guard PromptAlert.confirm(L("Перезаписать все значения свойства?"), detail: L("ИИ заново заполнит все записи, включая исправленные вручную. Потом можно нажать «Отменить заполнение»."), action: L("Перезаписать")) else { return }
                    filler.fill(property: property, model: model, shell: shell, scope: .all)
                }
                .buttonStyle(NotesButtonStyle(kind: .plain))
                .disabled(!AISettings.shared.isActive)
                if filler.lastRun[property.id] != nil {
                    Button(L("Отменить заполнение")) { filler.undoLastRun(property, model: model) }.buttonStyle(NotesButtonStyle(kind: .plain))
                }
            }
            Spacer()
            let owned = filler.aiOwnedCount(property, rows: model.rows)
            if owned > 0 {
                Text(String(format: L("✦ создано ИИ (на экране): %d"), owned)).font(.system(size: 11)).foregroundColor(AIStyle.tint)
            }
        }
    }
}

/// ✦ у ячейки, заполненной ИИ: значение совпадает с записанным ИИ. Ручная правка убирает значок.
struct AIMarkBadge: View {
    let property: UUID
    let record: UUID
    let value: PropertyValue?
    @ObservedObject private var filler = AIPropertyFiller.shared
    @EnvironmentObject private var shell: ShellModel

    var body: some View {
        Group {
            if value != nil, filler.marks[property]?[record] == AIValues.fingerprint(value) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundColor(AIStyle.tint)
                    .help(L("Заполнено ИИ"))
                    .accessibilityLabel(Text("Заполнено ИИ"))
            }
        }
        .task(id: property) {
            guard let store = shell.store else { return }
            await filler.ensureMarks(property, store: store)
        }
    }
}

/// Создание недостающих вариантов выбора в одном заполнении: не больше `AIValues.maxNewOptionsPerFill`,
/// без дублей (имена сверяются без учёта регистра и ё/е), цвета по кругу палитры.
@MainActor
final class AIOptionCreator {
    private let property: PropertyDefinition
    private let store: SQLiteWorkspace
    private var known: [PropertyOption]
    private(set) var created = 0
    /// Сколько названий не создано из-за предела.
    private(set) var skipped = 0

    init(property: PropertyDefinition, store: SQLiteWorkspace) {
        self.property = property
        self.store = store
        known = property.options
    }

    func value(for names: [String]) async -> PropertyValue? {
        let budget = AIValues.maxNewOptionsPerFill - created
        let plan = AIValues.planOptions(names, existing: known, budget: budget)
        let wanted = Set(names.compactMap(AIValues.cleanOptionName).map(SearchText.normalize)).count
        skipped += max(0, wanted - plan.count)
        var ids: [UUID] = []
        for choice in plan {
            switch choice {
            case .existing(let id):
                ids.append(id)
            case .new(let name):
                let id = UUID()
                let color = BlockColor.names[known.count % BlockColor.names.count]
                do {
                    try await store.addOption(property: property.id, name: name, color: color, id: id)
                    known.append(PropertyOption(id: id, name: name, color: color, sortKey: ""))
                    created += 1
                    ids.append(id)
                } catch {
                    continue
                }
            }
        }
        guard !ids.isEmpty else { return nil }
        return .options(property.type == .multiSelect ? ids : [ids[0]])
    }
}
