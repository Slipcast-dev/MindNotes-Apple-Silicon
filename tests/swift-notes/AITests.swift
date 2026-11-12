import AppKit
import Foundation

/// ИИ-ассистент (ADR-0016): всё без сети — разбор потока на записанных событиях, тело запроса, инструменты,
/// правила подтверждения и правки в настоящем редакторе.
@MainActor
func runAITests() async {
    _ = NSApplication.shared

    func feed(_ lines: [String]) -> AIResponseAccumulator {
        var acc = AIResponseAccumulator()
        for line in lines { if let e = AIStreamParser.parse(line: line) { acc.apply(e) } }
        return acc
    }

    await test("ИИ: поток текста собирается в ответ, учёт токенов и причина остановки") {
        let acc = feed([
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"usage":{"input_tokens":120,"output_tokens":1,"cache_read_input_tokens":100}}}"#,
            "",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"ping"}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Привет, "}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"мир 🦔"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":7}}"#,
            #"data: {"type":"message_stop"}"#,
        ])
        checkEqual(acc.turn.text, "Привет, мир 🦔")
        checkEqual(acc.turn.stopReason, "end_turn")
        check(acc.turn.finished)
        checkEqual(acc.turn.usage.input, 120)
        checkEqual(acc.turn.usage.output, 7)
        checkEqual(acc.turn.usage.cacheRead, 100)
        check(acc.streamError == nil)
    }

    await test("ИИ: вызов инструмента по частям JSON, размышления сохраняются как есть") {
        let acc = feed([
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"план"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig=="}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"search","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"отп"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"уск\", \"limit\": 5}"}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":30}}"#,
            #"data: {"type":"message_stop"}"#,
        ])
        checkEqual(acc.turn.stopReason, "tool_use")
        checkEqual(acc.turn.content.count, 2)
        checkEqual(acc.turn.content[0]["thinking"]?.stringValue, "план")
        checkEqual(acc.turn.content[0]["signature"]?.stringValue, "sig==")
        let uses = acc.turn.toolUses
        checkEqual(uses.count, 1)
        checkEqual(uses.first?.name, "search")
        checkEqual(uses.first?.input["query"]?.stringValue, "отпуск")
        check(acc.turn.invalidToolInputs.isEmpty)
        if let use = uses.first, case .success(let call) = AITools.validate(name: use.name, input: use.input) {
            checkEqual(call, .search(query: "отпуск", limit: 5))
        } else {
            check(false, "ввод разобран и проверен")
        }
    }

    await test("ИИ: обрезанный ввод инструмента помечается и не выполняется, ошибка потока видна") {
        let acc = feed([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_9","name":"create_page","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"title\": \"Обрез"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":64000}}"#,
        ])
        checkEqual(acc.turn.invalidToolInputs, ["toolu_9"])
        checkEqual(acc.turn.stopReason, "max_tokens")
        let broken = feed([#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#])
        checkEqual(broken.streamError?.type, "overloaded_error")
        check(AIStreamParser.parse(line: "data: не json") == nil, "мусор пропускается")
        check(AIStreamParser.parse(line: ": comment") == nil)
    }

    await test("ИИ: тело запроса — модель, усилие, отказоустойчивость, кеш; без temperature и prefill") {
        let body = AIRequest.body(system: "S", messages: [AIRequest.userText("Вопрос")], tools: AITools.definitions(), effort: .low)
        checkEqual(body["model"]?.stringValue, "claude-opus-5-5")
        checkEqual(body["stream"], .bool(true))
        checkEqual(body["max_tokens"]?.intValue, 64_000)
        checkEqual(body["output_config"]?["effort"]?.stringValue, "low")
        checkEqual(body["fallbacks"]?.stringValue, "default")
        checkEqual(body["tool_choice"]?["type"]?.stringValue, "auto", "принудительный выбор инструмента запрещён у модели")
        for banned in ["temperature", "top_p", "top_k", "thinking", "output_format"] { check(body[banned] == nil, banned) }
        checkEqual(body["system"]?.arrayValue?.first?["cache_control"]?["type"]?.stringValue, "ephemeral")
        let tools = body["tools"]?.arrayValue ?? []
        checkEqual(tools.count, 10)
        checkEqual(tools.last?["cache_control"]?["type"]?.stringValue, "ephemeral", "точка кеша — на последнем инструменте")
        check(tools.dropLast().allSatisfy { $0["cache_control"] == nil })
        // Строгая схема: у каждого объекта, включая вложенные, все поля обязательны и лишние запрещены.
        func checkStrict(_ schema: JSONValue?, _ name: String) {
            guard let schema else { return }
            if schema["type"]?.stringValue == "object" {
                checkEqual(schema["additionalProperties"], .bool(false), name)
                let keys = Set(schema["properties"]?.objectValue?.keys.map { $0 } ?? [])
                let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                checkEqual(keys, required, "все поля обязательны: \(name)")
                for (_, child) in schema["properties"]?.objectValue ?? [:] { checkStrict(child, name) }
            }
            if schema["type"]?.stringValue == "array" { checkStrict(schema["items"], name) }
        }
        for tool in tools {
            checkEqual(tool["strict"], .bool(true))
            checkEqual(tool["eager_input_streaming"], .bool(true))
            checkStrict(tool["input_schema"], tool["name"]?.stringValue ?? "")
        }
        checkEqual(tools.map { $0["name"]?.stringValue ?? "" }, ["search", "read_page", "list_pages", "create_page", "append_blocks", "update_block", "move_to_trash",
                                                                  "query_database", "create_database_rows", "update_properties"], "порядок постоянный")
        // Без инструментов нет и tool_choice.
        let plain = AIRequest.body(system: "S", messages: [], effort: .medium)
        check(plain["tools"] == nil && plain["tool_choice"] == nil)
        // JSON кодируется стабильно: одинаковое тело — одинаковые байты (кеш префикса).
        checkEqual(body.encoded(), AIRequest.body(system: "S", messages: [AIRequest.userText("Вопрос")], tools: AITools.definitions(), effort: .low).encoded())
    }

    await test("ИИ: проверка ввода инструментов") {
        let page = UUID(), block = UUID()
        func v(_ name: String, _ o: [String: JSONValue]) -> Result<AIToolCall, AITools.ValidationError> { AITools.validate(name: name, input: .object(o)) }
        checkEqual(try? v("read_page", ["page_id": .string(page.uuidString.lowercased())]).get(), .readPage(page))
        checkEqual(try? v("list_pages", ["parent_id": ""]).get(), .listPages(parent: nil), "пустой родитель — верхний уровень")
        checkEqual(try? v("create_page", ["parent_id": "", "title": "План", "markdown": "- [ ] а"]).get(), .createPage(parent: nil, title: "План", markdown: "- [ ] а"))
        checkEqual(try? v("update_block", ["page_id": .string(page.uuidString), "block_id": .string(block.uuidString), "text": ""]).get(),
                   .updateBlock(page: page, block: block, text: ""))
        checkEqual(try? v("search", ["query": "x", "limit": .int(500)]).get(), .search(query: "x", limit: 20), "лимит ограничен")
        check((try? v("read_page", ["page_id": "не-uuid"]).get()) == nil)
        check((try? v("create_page", ["parent_id": "", "title": "  ", "markdown": ""]).get()) == nil, "пустой заголовок")
        check((try? v("move_to_trash", ["page_id": .string(page.uuidString), "force": .bool(true)]).get()) == nil, "лишнее поле")
        if case .failure(let e) = v("delete_everything", [:]) { checkEqual(e, .unknownTool("delete_everything")) } else { check(false, "неизвестный инструмент") }
        check(!AIToolCall.search(query: "", limit: 1).mutates && AIToolCall.moveToTrash(page: page).mutates)
    }

    await test("ИИ: правка существующего и корзина всегда с подтверждением") {
        let p = UUID()
        for confirm in [true, false] {
            check(AIPolicy.needsConfirmation(.updateBlock(page: p, block: p, text: ""), confirmCreation: confirm))
            check(AIPolicy.needsConfirmation(.moveToTrash(page: p), confirmCreation: confirm))
            check(!AIPolicy.needsConfirmation(.readPage(p), confirmCreation: confirm))
        }
        check(AIPolicy.needsConfirmation(.createPage(parent: nil, title: "a", markdown: ""), confirmCreation: true))
        check(!AIPolicy.needsConfirmation(.createPage(parent: nil, title: "a", markdown: ""), confirmCreation: false))
        check(!AIPolicy.needsConfirmation(.appendBlocks(page: p, markdown: "a"), confirmCreation: false))
    }

    await test("ИИ: предложение — итог для модели и проверка версий страниц") {
        let a = UUID(), b = UUID()
        var proposal = AIProposal(id: 3, items: [
            .init(id: 1, call: .createPage(parent: nil, title: "А", markdown: ""), summary: "Создать А"),
            .init(id: 2, call: .moveToTrash(page: a), summary: "В корзину Б", selected: false),
        ])
        proposal.versions = [a: 10, b: 20]
        checkEqual(proposal.selectedCount, 1)
        checkEqual(proposal.changedPages(current: [a: 10, b: 20]), [])
        checkEqual(proposal.changedPages(current: [a: 11, b: 20]), [a])
        checkEqual(proposal.changedPages(current: [a: 10]), [b], "пропавшая страница считается изменившейся")
        check(proposal.outcomeNote == nil, "пока ждёт — итога нет")
        proposal.state = .applied(["Создать А"])
        let note = proposal.outcomeNote ?? ""
        check(note.contains("применил предложение 3") && note.contains("Создать А") && note.contains("Снято пользователем: 2. В корзину Б"), note)
        proposal.state = .rejected
        check(proposal.outcomeNote?.contains("Ничего не изменено") == true)
    }

    await test("ИИ: контекст из поиска — исключения и лимит, разметка источников экранируется") {
        let a = UUID(), b = UUID(), c = UUID()
        let hits = [SearchHit(pageID: a, blockID: nil, title: "План \"<x>\"", snippet: "раз"),
                    SearchHit(pageID: b, blockID: nil, title: "Секрет", snippet: "пароль"),
                    SearchHit(pageID: c, blockID: nil, title: "Длинная", snippet: String(repeating: "я", count: 500))]
        let built = AIContext.build(hits: hits, excluded: [b], limit: 300)
        checkEqual(built.sources.map(\.pageID), [a], "исключённая пропущена, длинная не влезла")
        check(!built.text.contains("пароль"))
        check(built.text.contains("План '‹x›'"), built.text)
        let block = Block(id: UUID(), pageID: a, sortKey: "a", type: .task, content: BlockContent(runs: [TextRun("Купить\nхлеб")]), createdAt: 1)
        let text = AIContext.pageText(title: "Т", blocks: [block])
        check(text.contains("[block \(block.id.uuidString.lowercased()) task] Купить хлеб"), text)
    }

    await test("ИИ: ошибки API — понятные сообщения и что повторять") {
        checkEqual(AIFailure.from(status: 401, body: Data(), retryAfter: nil), .badKey)
        checkEqual(AIFailure.from(status: 429, body: Data(), retryAfter: "12"), .rateLimited(retryAfter: 12))
        checkEqual(AIFailure.from(status: 529, body: Data(), retryAfter: nil), .overloaded)
        checkEqual(AIFailure.from(status: 503, body: Data(), retryAfter: nil), .server(503))
        checkEqual(AIFailure.from(status: 400, body: Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#.utf8), retryAfter: nil), .invalidRequest("bad"))
        check(AIFailure.overloaded.isRetryable && AIFailure.rateLimited(retryAfter: nil).isRetryable && AIFailure.offline.isRetryable)
        check(!AIFailure.badKey.isRetryable && !AIFailure.invalidRequest("").isRetryable && !AIFailure.refused(category: nil).isRetryable)
        check(AIFailure.badKey.errorDescription?.isEmpty == false)
    }

    await test("ИИ: пробел в пустом абзаце открывает ИИ, только если он доступен") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "Текст"), (.paragraph, ""), (.heading1, "")])
            var asked: [NSRange] = []
            r.controller.onAIRequest = { _, range in asked.append(range) }
            r.controller.aiAvailable = { false }
            r.caret(1, 0)
            r.type(" ")
            checkEqual(r.texts[1], " ", "без ИИ пробел вводится")
            r.tv.undo(nil)
            checkEqual(r.texts[1], "")
            r.controller.aiAvailable = { true }
            r.caret(1, 0)
            r.type(" ")
            for _ in 0..<3 { await Task.yield(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            checkEqual(r.texts[1], "", "пробел не вводится")
            checkEqual(asked.count, 1, "ИИ вызван")
            r.caret(0, 5)
            r.type(" ")
            checkEqual(r.texts[0], "Текст ", "в непустом абзаце пробел обычный")
            r.caret(2, 0)
            r.type(" ")
            checkEqual(asked.count, 1, "в заголовке пробел обычный")
            r.checkSync()
            try await r.close()
        }
    }

    await test("ИИ: «Заменить» и «Вставить ниже» — одной правкой отмены; изменившийся текст не трогается") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "Нужно сделать офлайн и копии"), (.paragraph, "Хвост")])
            r.select(0, 0, 0, 28)
            let range = r.tv.selectedRange()
            let original = (r.tv.string as NSString).substring(with: range)
            let fragments = MarkdownImport.fragments(from: "Требования:\n\n- офлайн\n- копии")
            check(r.controller.applyAI(range: range, expected: original, fragments: fragments, below: false))
            checkEqual(r.texts, ["Требования:", "офлайн", "копии", "Хвост"])
            checkEqual(r.types, [.paragraph, .bullet, .bullet, .paragraph])
            r.checkSync()
            r.tv.undo(nil)
            checkEqual(r.texts, ["Нужно сделать офлайн и копии", "Хвост"], "одна отмена возвращает исходное")

            r.select(0, 0, 0, 5)
            let range2 = r.tv.selectedRange()
            check(r.controller.applyAI(range: range2, expected: "Нужно", fragments: MarkdownImport.fragments(from: "Итог"), below: true))
            checkEqual(r.texts, ["Нужно сделать офлайн и копии", "Итог", "Хвост"], "ниже выделенного блока")
            r.tv.undo(nil)
            checkEqual(r.texts, ["Нужно сделать офлайн и копии", "Хвост"])

            var error: String?
            r.controller.onError = { error = $0 }
            check(!r.controller.applyAI(range: range2, expected: "Другой", fragments: fragments, below: false))
            check(error != nil, "сообщение об изменившемся тексте")
            checkEqual(r.texts, ["Нужно сделать офлайн и копии", "Хвост"], "ничего не изменено")
            r.checkSync()
            try await r.close()
        }
    }

    await test("ИИ-свойство: настройка в config.extra, строгий формат ответа, разбор значения") {
        let config = AIPropertyConfig(kind: .custom, prompt: "Тема одним словом")
        checkEqual(AIPropertyConfig(json: config.json), config, "туда и обратно")
        check(AIPropertyConfig(json: .object(["kind": "неизвестно"])) == nil)
        checkEqual(AIPropertyConfig.value(from: #"{"value": "  Отпуск "}"#), "Отпуск")
        check(AIPropertyConfig.value(from: "Отпуск") == nil, "не по схеме — не пишется")
        let request = config.request(title: "Поездка", properties: [("Статус", "В работе"), ("Пусто", "")], body: "Билеты и отель")
        check(request.contains("Тема одним словом") && request.contains("<record>") && request.contains("Статус: В работе") && !request.contains("Пусто"), request)
        let body = AIRequest.body(system: AIPropertyConfig.system, messages: [AIRequest.userText(request)], effort: .low, maxTokens: 2_048, format: AIPropertyConfig.format)
        checkEqual(body["output_config"]?["format"]?["type"]?.stringValue, "json_schema")
        checkEqual(body["output_config"]?["format"]?["schema"]?["additionalProperties"], .bool(false))
        checkEqual(body["output_config"]?["effort"]?.stringValue, "low")
        check(body["tools"] == nil)
        // Для пакета: без stream и без fallbacks (beta-заголовок пакетам не отправляется).
        let batch = AIRequest.body(system: "S", messages: [], effort: .low, stream: false, maxTokens: 10, fallbacks: false)
        check(batch["stream"] == nil && batch["fallbacks"] == nil)
    }

    await test("ИИ-свойство: запись в config_json не трогает другие настройки и переживает чтение") {
        try await withTempDir { dir in
            let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { w.close() }
            let template = NewDatabase(title: "Задачи", titleProperty: "Название", statusProperty: "Статус", statusOptions: ["А"], dateProperty: "Срок", viewName: "Таблица")
            let d = try await w.createDatabase(parent: nil, template: template, ids: RandomIDs(), now: 1)
            let text = UUID()
            try await w.addProperty(database: d.id, name: "Кратко", type: .text, id: text, now: 2)
            try await w.setPropertyExtra(text, key: AIPropertyConfig.key, value: AIPropertyConfig(kind: .summary).json)
            try await w.setPropertyExtra(text, key: "other", value: .string("keep"))
            var loaded = try await w.database(d.id)?.property(text)
            checkEqual(AIPropertyConfig(json: loaded?.config.extra[AIPropertyConfig.key])?.kind, .summary)
            checkEqual(loaded?.type, .text, "тип прежний: старые версии видят обычный текст")
            try await w.setPropertyExtra(text, key: AIPropertyConfig.key, value: nil)
            loaded = try await w.database(d.id)?.property(text)
            check(loaded?.config.extra[AIPropertyConfig.key] == nil)
            checkEqual(loaded?.config.extra["other"], .string("keep"), "чужое поле сохранено")
            await checkThrows("нет свойства") { try await w.setPropertyExtra(UUID(), key: "ai", value: nil) }
        }
    }

    await test("ИИ: скрытые страницы — с подстраницами, без зацикливания; кодирование") {
        let root = UUID(), child = UUID(), grandchild = UUID(), other = UUID()
        let parents: [UUID: UUID] = [child: root, grandchild: child]
        check(AIExclusion.isExcluded(grandchild, excluded: [root]) { parents[$0] })
        check(!AIExclusion.isExcluded(other, excluded: [root]) { parents[$0] })
        check(!AIExclusion.isExcluded(root, excluded: [child]) { parents[$0] }, "родитель скрытой не скрыт")
        let loop: [UUID: UUID] = [root: child, child: root]
        check(!AIExclusion.isExcluded(root, excluded: [other]) { loop[$0] }, "цикл не зависает")
        checkEqual(AIExclusion.decode(AIExclusion.encode([root, child])), [root, child])
        checkEqual(AIExclusion.decode(nil), [])
        checkEqual(AIExclusion.decode("мусор,\(root.uuidString)"), [root])
    }

    await test("ИИ: история чатов — порядок, пределы количества и объёма") {
        func chat(_ n: Int, size: Int = 10) -> AIStoredChat {
            AIStoredChat(id: UUID(), title: "Ч\(n)", updatedAt: Int64(n), lines: [.init(role: .user, text: "в")],
                         messages: [AIRequest.userText(String(repeating: "я", count: size))])
        }
        let list = (1...40).map { chat($0) }
        let decoded = AIStoredChat.decode(AIStoredChat.encode(list))
        checkEqual(decoded.count, AIStoredChat.maxChats)
        checkEqual(decoded.first?.title, "Ч40", "новые первыми")
        checkEqual(decoded.first?.messages, list.last?.messages, "история API сохраняется без потерь")
        let big = (1...5).map { chat($0, size: 900_000) }
        let trimmed = AIStoredChat.decode(AIStoredChat.encode(big))
        check(trimmed.count < 5 && trimmed.first?.title == "Ч5", "старые отброшены по объёму: \(trimmed.count)")
        checkEqual(AIStoredChat.decode("не json"), [])
        checkEqual(AIStoredChat.title(from: "Первая строка\nвторая"), "Первая строка")
        check(AIStoredChat.title(from: String(repeating: "а", count: 100)).count == 61)
    }

    await test("ИИ: подсказка на пустой строке — только с ИИ и только в пустом абзаце") {
        try await withTempDir { dir in
            let r = try await EditorRig(dir: dir, blocks: [(.paragraph, "Текст"), (.paragraph, ""), (.heading1, "")])
            r.controller.aiAvailable = { true }
            r.caret(1, 0)
            r.controller.updateAIHint()
            check(r.tv.aiHintRect != nil, "в пустом абзаце есть")
            r.type("а")
            check(r.tv.aiHintRect == nil, "после ввода нет")
            r.caret(2, 0)
            r.controller.updateAIHint()
            check(r.tv.aiHintRect == nil, "в заголовке нет")
            r.controller.aiAvailable = { false }
            r.tv.undo(nil)
            r.caret(1, 0)
            r.controller.updateAIHint()
            check(r.tv.aiHintRect == nil, "без ИИ нет")
            checkEqual(r.texts[1], "", "подсказка не входит в текст")
            r.checkSync()
            try await r.close()
        }
    }

    func prop(_ type: PropertyType, _ options: [String] = []) -> PropertyDefinition {
        var p = PropertyDefinition(id: UUID(), databaseID: UUID(), name: "Поле", type: type, sortKey: "a")
        p.options = options.enumerated().map { PropertyOption(id: UUID(), name: $1, color: nil, sortKey: "\($0)") }
        return p
    }

    await test("ИИ-значения: схема и разбор по типу свойства, выбор только из вариантов") {
        let status = prop(.status, ["Новая", "В работе", "Готово"])
        checkEqual(AIValues.schema(for: status)["enum"]?.arrayValue?.count, 3)
        checkEqual(AIValues.format(for: prop(.number))["schema"]?["properties"]?["value"]?["type"]?.stringValue, "number")
        checkEqual(AIValues.value(from: .string("в работе"), property: status), .some(.options([status.options[1].id])), "регистр не важен")
        check(AIValues.value(from: .string("Выдумка"), property: status) == .none, "нет такого варианта")
        checkEqual(AIValues.value(from: .int(42), property: prop(.number)), .some(.number(42)))
        checkEqual(AIValues.value(from: .string(""), property: prop(.text)), .some(nil), "пусто — очистить")
        let tags = prop(.multiSelect, ["а", "б", "в"])
        checkEqual(AIValues.value(from: .array(["б", "б", "г", "а"]), property: tags), .some(.options([tags.options[1].id, tags.options[0].id])), "повторы и чужие убраны")
        checkEqual(AIValues.parse("2026-12-01", property: prop(.date)), .date(DateValue(start: .day(LocalDate(iso: "2026-12-01")!))))
        check(AIValues.parse("завтра", property: prop(.date)) == nil)
        checkEqual(AIValues.parse("1 234,5", property: prop(.number)), .number(1234.5))
        checkEqual(AIValues.parse("да", property: prop(.checkbox)), .checkbox(true))
        check(AIValues.parse("javascript:alert(1)", property: prop(.url)) == nil, "опасный адрес не принимается")
        check(!AIValues.fillable.contains(.formula) && !AIValues.fillable.contains(.relation))
    }

    await test("ИИ-значения: отметка «создано ИИ» и что перезаписывать") {
        let v: PropertyValue = .text("Итог")
        checkEqual(AIValues.fingerprint(v), AIValues.fingerprint(.text("Итог")), "устойчив")
        check(AIValues.fingerprint(v) != AIValues.fingerprint(.text("Итог!")))
        let mark = AIValues.fingerprint(v)
        check(AIValues.shouldFill(nil, mark: nil, scope: .empty))
        check(!AIValues.shouldFill(v, mark: mark, scope: .empty), "непустое не трогается")
        check(AIValues.shouldFill(v, mark: mark, scope: .aiOwned), "созданное ИИ обновляется")
        check(!AIValues.shouldFill(.text("Исправлено руками"), mark: mark, scope: .aiOwned), "ручная правка снимает отметку")
        check(AIValues.shouldFill(.text("Исправлено руками"), mark: mark, scope: .all))
        let page = UUID()
        checkEqual(AIValues.decodeMarks(AIValues.encodeMarks([page: mark])), [page: mark])
        checkEqual(AIValues.decodeMarks("мусор"), [:])
    }

    await test("ИИ: инструменты баз — проверка ввода, разбор значений по именам, подтверждение") {
        let db = UUID()
        func v(_ name: String, _ o: [String: JSONValue]) -> AIToolCall? { try? AITools.validate(name: name, input: .object(o)).get() }
        let pair: JSONValue = .object(["property": "Статус", "value": "Готово"])
        checkEqual(v("create_database_rows", ["database_id": .string(db.uuidString), "rows": .array([.object(["title": "Купить", "values": .array([pair])])])]),
                   .createRows(database: db, rows: [AIRowInput(title: "Купить", values: [AIPropertyInput(property: "Статус", value: "Готово")])]))
        check(v("create_database_rows", ["database_id": .string(db.uuidString), "rows": .array([])]) == nil, "пустой список")
        check(v("update_properties", ["page_id": .string(db.uuidString), "values": .array([.object(["property": "a", "value": "b", "x": "y"])])]) == nil, "лишнее поле")
        checkEqual(v("query_database", ["database_id": .string(db.uuidString), "limit": .int(9999)]), .queryDatabase(database: db, limit: 200))
        check(AIPolicy.needsConfirmation(.updateProperties(page: db, values: []), confirmCreation: false), "правка свойств — всегда с вопросом")
        check(!AIPolicy.needsConfirmation(.createRows(database: db, rows: []), confirmCreation: false))
        check(!AIToolCall.queryDatabase(database: db, limit: 1).mutates)

        var status = prop(.status, ["Новая", "Готово"]); status.name = "Статус"
        var due = prop(.date); due.name = "Срок"
        var title = prop(.title); title.name = "Название"
        let database = Database(id: UUID(), pageID: db, properties: [title, status, due], views: [])
        if case .success(let values) = AIValues.resolve([AIPropertyInput(property: "статус", value: "готово"), AIPropertyInput(property: "Срок", value: "2026-12-01")], database: database) {
            checkEqual(values.map(\.property.id), [status.id, due.id])
        } else { check(false, "значения разобраны") }
        if case .failure(let e) = AIValues.resolve([AIPropertyInput(property: "Название", value: "x")], database: database) {
            check(e.message.contains("доступны: Статус, Срок"), e.message)
        } else { check(false, "заголовок не задаётся как свойство") }
        if case .failure(let e) = AIValues.resolve([AIPropertyInput(property: "Срок", value: "скоро")], database: database) {
            check(e.message.contains("ГГГГ-ММ-ДД"), e.message)
        } else { check(false, "неверная дата") }
        check(AIValues.schemaText(database).contains("- Статус: один вариант из: Новая, Готово"))
    }

    await test("ИИ: файлы в чате — типы, пределы и история без содержимого") {
        let png = AIAttachment.make(name: "a.png", ext: "PNG", data: Data([1, 2, 3]))
        checkEqual(png?.block["source"]?["media_type"]?.stringValue, "image/png")
        checkEqual(AIAttachment.make(name: "d.pdf", ext: "pdf", data: Data([1]))?.block["type"]?.stringValue, "document")
        checkEqual(AIAttachment.make(name: "n.md", ext: "md", data: Data("Текст".utf8))?.block["source"]?["data"]?.stringValue, "Текст")
        check(AIAttachment.make(name: "x.exe", ext: "exe", data: Data([1])) == nil)
        check(AIAttachment.make(name: "big.png", ext: "png", data: Data(count: AIAttachment.maxImageBytes + 1)) == nil)
        let message = AIRequest.user([png!.block, .object(["type": "text", "text": "Что на картинке?"])])
        let stored = AIAttachment.strippedForStorage([message, AIRequest.assistant([.object(["type": "text", "text": "Кот"])])])
        let content = stored[0]["content"]?.arrayValue ?? []
        checkEqual(content.map { $0["type"]?.stringValue ?? "" }, ["text", "text"])
        check(!String(decoding: JSONValue.array(stored).encoded(), as: UTF8.self).contains(Data([1, 2, 3]).base64EncodedString()), "данных файла нет")
        checkEqual(stored[1], AIRequest.assistant([.object(["type": "text", "text": "Кот"])]), "ответы не меняются")
    }

    await test("ИИ: результат пакета — ответ без стриминга разбирается так же") {
        let message = JSONValue.parse(#"{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"{\"value\": \"Отпуск\"}"}],"stop_reason":"end_turn","usage":{"input_tokens":50,"output_tokens":9}}"#)!
        let turn = AIAssistantTurn(message: message)
        checkEqual(turn.stopReason, "end_turn")
        checkEqual(turn.usage.input, 50)
        checkEqual(AIValues.value(from: JSONValue.parse(turn.text)?["value"], property: prop(.text)), .some(.text("Отпуск")))
    }

    await test("Провайдеры: каталог и адреса — https или http только на этот Mac") {
        check(AIProvider.builtIn.count >= 9)
        check(Set(AIProvider.builtIn.map(\.id)).count == AIProvider.builtIn.count, "ID без повторов")
        for p in AIProvider.builtIn { check(AIProvider.isAllowedBaseURL(p.baseURL), p.id) }
        check(AIProvider.find("deepseek", customURL: "").name == "DeepSeek")
        checkEqual(AIProvider.find("нет такого", customURL: "").id, "anthropic", "неизвестный — Anthropic")
        checkEqual(AIProvider.find("custom", customURL: "https://llm.example.com/v1").baseURL, "https://llm.example.com/v1")
        check(AIProvider.isAllowedBaseURL("http://localhost:11434/v1") && AIProvider.isAllowedBaseURL("http://127.0.0.1:8080"))
        check(!AIProvider.isAllowedBaseURL("http://192.168.1.5:8080/v1"), "http по сети — нет")
        check(!AIProvider.isAllowedBaseURL("https://user:pass@example.com/v1"), "без логина в адресе")
        check(!AIProvider.isAllowedBaseURL("ftp://example.com") && !AIProvider.isAllowedBaseURL("example.com"))
        checkEqual(AIProvider.normalizedBaseURL(" https://x.ai/v1/chat/completions/ "), "https://x.ai/v1")
        check(AIProvider.anthropic.batches && !AIProvider.openAI.batches)
        check(AIProvider.ollama.isLocal && !AIProvider.ollama.needsKey && !AIProvider.gemini.isLocal)
    }

    await test("Провайдеры: запрос в формате OpenAI — система, файлы, инструменты, результаты") {
        let image = AIAttachment.make(name: "a.png", ext: "png", data: Data([7]))!.block
        let pdf = AIAttachment.make(name: "d.pdf", ext: "pdf", data: Data([8]))!.block
        let messages: [JSONValue] = [
            AIRequest.user([.object(["type": "text", "text": "Контекст"]), image, pdf, .object(["type": "text", "text": "Вопрос"])]),
            AIRequest.assistant([.object(["type": "thinking", "thinking": "скрыто", "signature": "s"]), .object(["type": "text", "text": "Ищу"]),
                                 .object(["type": "tool_use", "id": "toolu_1", "name": "search", "input": .object(["query": "отпуск", "limit": .int(5)])])]),
            AIRequest.user([AIRequest.toolResult(id: "toolu_1", text: "нет", isError: true)]),
        ]
        let anthropic = AIRequest.body(model: "gpt-5", system: "Правила", messages: messages, tools: AITools.definitions(), effort: .low, maxTokens: 64_000)
        let body = AIOpenAI.body(from: anthropic, provider: .openAI)
        let out = body["messages"]?.arrayValue ?? []
        checkEqual(out.map { $0["role"]?.stringValue ?? "" }, ["system", "user", "assistant", "tool"])
        checkEqual(out[0]["content"]?.stringValue, "Правила")
        let parts = out[1]["content"]?.arrayValue ?? []
        checkEqual(parts.map { $0["type"]?.stringValue ?? "" }, ["text", "image_url", "file", "text"])
        check(parts[1]["image_url"]?["url"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
        checkEqual(out[2]["content"]?.stringValue, "Ищу", "размышления не передаются")
        let call = out[2]["tool_calls"]?.arrayValue?.first
        checkEqual(call?["function"]?["name"]?.stringValue, "search")
        checkEqual(JSONValue.parse(call?["function"]?["arguments"]?.stringValue ?? "")?["query"]?.stringValue, "отпуск")
        checkEqual(out[3]["tool_call_id"]?.stringValue, "toolu_1")
        checkEqual(out[3]["content"]?.stringValue, "Ошибка: нет")
        checkEqual(body["max_completion_tokens"]?.intValue, AIProvider.openAI.maxOutput, "предел провайдера")
        check(body["max_tokens"] == nil && body["output_config"] == nil && body["fallbacks"] == nil && body["system"] == nil)
        checkEqual(body["stream_options"]?["include_usage"], .bool(true))
        let tools = body["tools"]?.arrayValue ?? []
        checkEqual(tools.count, 10)
        checkEqual(tools.first?["type"]?.stringValue, "function")
        checkEqual(tools.first?["function"]?["strict"], .bool(true), "строгие схемы у OpenAI")

        let deep = AIOpenAI.body(from: anthropic, provider: .deepSeek)
        let deepParts = deep["messages"]?.arrayValue?[1]["content"]
        check(deepParts?.stringValue?.contains("не принимает изображения") == true && deepParts?.stringValue?.contains("не принимает PDF") == true,
              "без поддержки файлов — пометка вместо данных")
        checkEqual(deep["max_tokens"]?.intValue, 8_000)
        check(deep["tools"]?.arrayValue?.first?["function"]?["strict"] == nil)

        let gemini = AIOpenAI.body(from: anthropic, provider: .gemini)
        check(!String(decoding: (gemini["tools"] ?? .null).encoded(), as: UTF8.self).contains("additionalProperties"), "Gemini без additionalProperties")
    }

    await test("Провайдеры: строгий формат ответа — json_schema или json_object") {
        var status = PropertyDefinition(id: UUID(), databaseID: UUID(), name: "Статус", type: .status, sortKey: "a")
        status.options = [PropertyOption(id: UUID(), name: "Готово", color: nil, sortKey: "a")]
        let anthropic = AIRequest.body(model: "m", system: "S", messages: [AIRequest.userText("x")], effort: .low, stream: false, maxTokens: 100, format: AIValues.format(for: status))
        let openAI = AIOpenAI.body(from: anthropic, provider: .openAI)
        checkEqual(openAI["response_format"]?["type"]?.stringValue, "json_schema")
        checkEqual(openAI["response_format"]?["json_schema"]?["schema"]?["properties"]?["value"]?["enum"], .array(["Готово"]))
        check(openAI["stream"] == nil)
        checkEqual(AIOpenAI.body(from: anthropic, provider: .deepSeek)["response_format"]?["type"]?.stringValue, "json_object")
        checkEqual(AIOpenAI.body(from: anthropic, provider: .ollama)["messages"]?.arrayValue?.last?["content"]?.stringValue, "x", "только текст — строкой")
    }

    await test("Провайдеры: поток OpenAI собирается в ответ — текст, инструменты, причины, токены") {
        var acc = AIOpenAIAccumulator()
        for line in [
            #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"При"}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"content":"вет"}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"read_page","arguments":"{\"page_"}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"id\": \"x\"}"}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":15,"prompt_tokens_details":{"cached_tokens":100}}}"#,
            ": keep-alive",
        ] { acc.apply(line: line) }
        check(acc.apply(line: "data: [DONE]"), "конец потока")
        checkEqual(acc.turn.text, "Привет")
        checkEqual(acc.turn.stopReason, "tool_use")
        check(acc.turn.finished)
        checkEqual(acc.turn.toolUses.first?.name, "read_page")
        checkEqual(acc.turn.toolUses.first?.input["page_id"]?.stringValue, "x")
        checkEqual(acc.turn.toolUses.first?.id, "call_a")
        checkEqual(acc.turn.usage.input, 120)
        checkEqual(acc.turn.usage.cacheRead, 100)
        check(acc.turn.invalidToolInputs.isEmpty)

        var cut = AIOpenAIAccumulator()
        cut.apply(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"create_page","arguments":"{\"title\": \"Обре"}}]},"finish_reason":"length"}]}"#)
        cut.apply(line: "data: [DONE]")
        checkEqual(cut.turn.stopReason, "max_tokens")
        checkEqual(cut.turn.invalidToolInputs, ["c"], "обрезанный ввод не выполняется")

        var filtered = AIOpenAIAccumulator()
        filtered.apply(line: #"data: {"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#)
        checkEqual(filtered.turn.stopReason, "refusal")

        var broken = AIOpenAIAccumulator()
        broken.apply(line: #"data: {"error":{"message":"bad model"}}"#)
        checkEqual(broken.streamError, "bad model")

        // Сервер написал «stop», хотя вызвал инструмент: считается вызовом.
        var odd = AIOpenAIAccumulator()
        odd.apply(response: JSONValue.parse(#"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"search","arguments":"{\"query\":\"a\",\"limit\":3}"}}]},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}"#)!)
        checkEqual(odd.turn.stopReason, "tool_use")
        if let use = odd.turn.toolUses.first, case .success(let c) = AITools.validate(name: use.name, input: use.input) {
            checkEqual(c, .search(query: "a", limit: 3))
        } else { check(false, "вызов разобран") }
    }

    await test("ИИ: снимок заполнения для отмены переживает перезапуск без потерь") {
        let a = UUID(), b = UUID(), c = UUID(), opt = UUID()
        let moment = DateValue(start: .moment(ms: 1_700_000_000_000, zone: "Europe/Moscow"), end: .day(LocalDate(iso: "2026-12-01")!))
        let old: [(page: UUID, value: PropertyValue?)] = [(a, .text("было")), (b, .options([opt])), (c, nil)]
        let text = AIValues.encodeRun(database: a, old: old + [(b, .date(moment)), (c, .number(2.5)), (a, .checkbox(true)), (b, .url("https://x.ru"))],
                                      marks: [a: "f1"])
        let property = PropertyDefinition(id: UUID(), databaseID: a, name: "П", type: .text, sortKey: "a")
        guard let run = AIValues.decodeRun(text, property: property) else { return check(false, "снимок прочитан") }
        checkEqual(run.database, a)
        checkEqual(run.marks, [a: "f1"])
        checkEqual(run.old.map(\.value), [.text("было"), .options([opt]), nil, .date(moment), .number(2.5), .checkbox(true), .url("https://x.ru")])
        check(AIValues.decodeRun("мусор", property: property) == nil)
    }

    await test("ИИ: агент задаёт людей и связи по именам") {
        let anna = Person(id: UUID(), name: "Анна"), boris = Person(id: UUID(), name: "Борис")
        let target = UUID(), linked = LinkedPage(id: UUID(), title: "Проект Альфа")
        var who = PropertyDefinition(id: UUID(), databaseID: UUID(), name: "Исполнитель", type: .person, sortKey: "a")
        var link = PropertyDefinition(id: UUID(), databaseID: who.databaseID, name: "Проект", type: .relation, sortKey: "b")
        link.config = PropertyConfig(target: target)
        let look = AIValueLookups(people: [anna, boris], records: [target: [linked]])
        checkEqual(AIValues.parse("анна, Борис, анна", property: who, lookups: look), .people([anna, boris]), "регистр не важен, без повторов")
        check(AIValues.parse("Вася", property: who, lookups: look) == nil, "нет такого человека")
        checkEqual(AIValues.parse("проект альфа", property: link, lookups: look), .relation([linked]))
        checkEqual(AIValues.parse(linked.id.uuidString, property: link, lookups: look), .relation([linked]), "по ID записи")
        check(AIValues.parse("Бета", property: link, lookups: look) == nil)
        who.name = "Исполнитель"
        let database = Database(id: who.databaseID, pageID: UUID(), properties: [who, link], views: [])
        if case .success(let values) = AIValues.resolve([AIPropertyInput(property: "исполнитель", value: "Анна"), AIPropertyInput(property: "Проект", value: "Проект Альфа")],
                                                        database: database, lookups: look) {
            checkEqual(values.map(\.value), [.people([anna]), .relation([linked])])
        } else { check(false, "люди и связи разобраны") }
        check(AIValues.schemaText(database).contains("имена через запятую"))
        check(!AIValues.fillable.contains(.person), "ИИ-заполнение людей не трогает")
    }

    await test("ИИ: ответ «модель не умеет инструменты» распознаётся") {
        check(AIFailure.mentionsTools("registry.ollama.ai/library/gemma does not support tools"))
        check(AIFailure.mentionsTools("Function calling is not supported for this model"))
        check(!AIFailure.mentionsTools("Invalid API key"))
        check(!AIFailure.mentionsTools("max_tokens is too large"))
    }

    await test("ИИ-свойство: новые варианты выбора — без дублей и не больше предела") {
        let work = PropertyOption(id: UUID(), name: "Работа", color: nil, sortKey: "a")
        let home = PropertyOption(id: UUID(), name: "Ёлка", color: nil, sortKey: "b")
        let plan = AIValues.planOptions(["работа", " «Учёба». ", "елка", "Учеба", "", String(repeating: "я", count: 61), "Спорт"], existing: [work, home], budget: 1)
        checkEqual(plan, [.existing(work.id), .new("Учёба"), .existing(home.id)], "регистр, ё/е, кавычки и точка не важны; предел — 1 новый")
        checkEqual(AIValues.planOptions(["А", "Б"], existing: [], budget: 0), [], "предел исчерпан")
        checkEqual(AIValues.cleanOptionName("  много   пробелов "), "много пробелов")
        check(AIValues.maxNewOptionsPerFill == 10)

        var tags = PropertyDefinition(id: UUID(), databaseID: UUID(), name: "Теги", type: .multiSelect, sortKey: "a")
        tags.options = [work]
        checkEqual(AIValues.optionNames(from: .array(["а", "б"]), property: tags), ["а", "б"])
        checkEqual(AIValues.optionNames(from: .string("а, б"), property: tags), ["а", " б"])
        checkEqual(AIValues.optionNames(from: .null, property: tags), [])
        let text = PropertyDefinition(id: UUID(), databaseID: UUID(), name: "Т", type: .text, sortKey: "a")
        check(AIValues.optionNames(from: .string("а"), property: text) == nil, "не выбор")

        // Разрешены новые: в схеме нет enum, существующие — подсказкой; у статуса enum остаётся.
        let open = AIValues.schema(for: tags, allowNew: true)
        check(open["items"]?["enum"] == nil && open["items"]?["description"]?.stringValue?.contains("Работа") == true)
        checkEqual(AIValues.schema(for: tags)["items"]?["enum"], .array(["Работа"]), "без разрешения — только существующие")
        var status = PropertyDefinition(id: UUID(), databaseID: UUID(), name: "С", type: .status, sortKey: "a")
        status.options = [work]
        checkEqual(AIValues.schema(for: status, allowNew: true)["enum"], .array(["Работа"]), "статус — только свои варианты")

        let config = AIPropertyConfig(kind: .extract)
        check(config.newOptions && config.createsOptions(tags) && !config.createsOptions(status) && !config.createsOptions(text))
        check(AIPropertyConfig(json: config.json)?.newOptions == true, "по умолчанию включено и не пишется лишним полем")
        check(config.json["newOptions"] == nil)
        let off = AIPropertyConfig(kind: .extract, newOptions: false)
        checkEqual(AIPropertyConfig(json: off.json)?.newOptions, false)
        check(!off.createsOptions(tags))
        check(config.request(title: "З", properties: [], body: "", target: tags).contains("новый короткий вариант"))
        check(!off.request(title: "З", properties: [], body: "", target: tags).contains("новый"))
    }
}
