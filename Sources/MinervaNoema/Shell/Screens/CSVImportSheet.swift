import SwiftUI

/// Файл CSV, выбранный для импорта: данные прочитаны один раз, оригинал больше не открывается.
struct CSVImportRequest: Identifiable {
    let id = UUID()
    let url: URL
    let data: Data
}

/// Предпросмотр CSV (FR-14.2): кодировка, разделитель, строка заголовков и тип каждого столбца.
struct CSVImportSheet: View {
    @EnvironmentObject private var shell: ShellModel
    @Environment(\.dismiss) private var dismiss
    let request: CSVImportRequest

    private enum Encoding: String, CaseIterable, Identifiable {
        case auto, utf8, cp1251, utf16
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return L("Автоматически")
            case .utf8: return "UTF-8"
            case .cp1251: return "Windows-1251"
            case .utf16: return "UTF-16"
            }
        }
        var value: String.Encoding? {
            switch self {
            case .auto: return nil
            case .utf8: return .utf8
            case .cp1251: return .windowsCP1251
            case .utf16: return .utf16
            }
        }
    }

    @State private var encoding = Encoding.auto
    @State private var delimiter: Character = ","
    @State private var hasHeader = true
    @State private var title = ""
    @State private var plan: CSVImportPlanState?
    @State private var error: String?
    /// Разделитель определяется один раз, дальше его выбирает пользователь.
    @State private var detectedDelimiter = false

    /// План и выбор типов; пересчитывается при смене кодировки, разделителя или заголовков.
    private struct CSVImportPlanState {
        var plan: CSVImport.Plan
        var detected: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Импорт таблицы").font(.system(size: 15, weight: .semibold)).padding(16)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Название базы").frame(width: 130, alignment: .leading)
                    TextField("", text: $title).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Кодировка").frame(width: 130, alignment: .leading)
                    Picker("", selection: $encoding) { ForEach(Encoding.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().frame(width: 180)
                    if let detected = plan?.detected, encoding == .auto { Text(detected).foregroundColor(Tokens.muted).font(.system(size: 12)) }
                }
                HStack {
                    Text("Разделитель").frame(width: 130, alignment: .leading)
                    Picker("", selection: $delimiter) {
                        Text(L("Запятая")).tag(Character(","))
                        Text(L("Точка с запятой")).tag(Character(";"))
                        Text(L("Табуляция")).tag(Character("\t"))
                    }
                    .labelsHidden().frame(width: 180)
                    Toggle("Первая строка — названия столбцов", isOn: $hasHeader)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            Rectangle().fill(Tokens.line).frame(height: 1)
            if let error {
                Text(error).foregroundColor(.red).padding(16).frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
            } else if let state = plan {
                preview(state.plan)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 280)
            }
            Rectangle().fill(Tokens.line).frame(height: 1)
            HStack {
                if let state = plan {
                    Text(String(format: L("Записей: %d, столбцов: %d. Файл не изменится."), state.plan.rows.count, state.plan.headers.count))
                        .font(.system(size: 12)).foregroundColor(Tokens.muted)
                }
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(NotesButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Импортировать") {
                    guard let state = plan else { return }
                    dismiss()
                    shell.importCSV(request, plan: state.plan, title: title)
                }
                .buttonStyle(NotesButtonStyle(kind: .primary))
                .disabled(plan == nil || plan?.plan.rows.isEmpty == true || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 760)
        .background(Tokens.paper)
        .onAppear { title = FolderImport.cleanTitle(request.url.lastPathComponent) }
        // Разбор большого файла — вне главного потока; новый выбор отменяет прежний разбор.
        .task(id: Settings(encoding: encoding, delimiter: delimiter, hasHeader: hasHeader)) { await reload() }
    }

    private struct Settings: Equatable {
        var encoding: Encoding
        var delimiter: Character
        var hasHeader: Bool
    }

    private func reload() async {
        let data = request.data, chosen = encoding.value, header = hasHeader, zone = TimeZone.current.identifier
        let first = !detectedDelimiter
        let separator = delimiter
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(CSVImport.Plan, String, Character), Error> in
            Result {
                let decoded = try TextFileReader.decode(data, as: chosen)
                let used = first ? CSV.detectDelimiter(decoded.text) : separator
                let table = CSV.parse(decoded.text, delimiter: used)
                return (CSVImport.plan(table, hasHeader: header, zone: zone), decoded.encoding, used)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let (fresh, detected, used)):
            var fresh = fresh
            // Выбранные вручную типы сохраняются, если столбцы те же.
            if let old = plan?.plan, old.headers == fresh.headers { fresh.types = old.types }
            plan = CSVImportPlanState(plan: fresh, detected: detected)
            error = nil
            if first { detectedDelimiter = true; delimiter = used }
        case .failure:
            plan = nil
            error = L("Файл не читается в этой кодировке. Выберите другую.")
        }
    }

    private func preview(_ plan: CSVImport.Plan) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(plan.headers.enumerated()), id: \.offset) { i, name in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            if i == 0 {
                                Text(PropertyType.title.title).font(.system(size: 11)).foregroundColor(Tokens.muted)
                            } else {
                                Picker("", selection: Binding(get: { self.plan?.plan.types[i] ?? .text },
                                                              set: { self.plan?.plan.types[i] = $0 })) {
                                    ForEach(PropertyType.creatable, id: \.self) { Text($0.title).tag($0) }
                                }
                                .labelsHidden()
                                .controlSize(.small)
                            }
                        }
                        .frame(width: 150, alignment: .leading)
                        .padding(6)
                    }
                }
                Rectangle().fill(Tokens.line).frame(height: 1)
                ForEach(Array(plan.rows.prefix(10).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(.system(size: 12)).lineLimit(1).frame(width: 150, alignment: .leading).padding(6)
                        }
                    }
                }
            }
            .padding(10)
        }
        .frame(height: 280)
    }
}
