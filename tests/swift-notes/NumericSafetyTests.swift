import Foundation

/// Недостоверные числа из чужой базы и от AI endpoint не должны вызывать аварийное завершение
/// (аудит: revision-timestamp-overflow, ai-json-unsafe-integer-conversion).
@MainActor
func runNumericSafetyTests() async {
    await test("История: крайние даты снимков не вызывают переполнения") {
        let p = RevisionPolicy()
        for last in [Int64.min, Int64.max, 5_000_000] {
            check(p.isDue(dirty: true, lastSnapshotAt: last, now: 1_000), "недостоверная дата \(last): снимок нужен")
        }
        check(!p.isDue(dirty: true, lastSnapshotAt: -1, now: 1_000), "отрицательная прошедшая дата — обычная разность")
        check(p.isDue(dirty: true, lastSnapshotAt: Int64.min, now: Int64.max))
        check(p.isDue(dirty: true, lastSnapshotAt: Int64.max, now: Int64.min))
        check(!p.isDue(dirty: true, lastSnapshotAt: 0, now: RevisionPolicy.minInterval - 1), "обычная частота сохранена")
        check(p.isDue(dirty: true, lastSnapshotAt: 0, now: RevisionPolicy.minInterval))
        check(!p.isDue(dirty: false, lastSnapshotAt: Int64.min, now: 1))

        let page = UUID()
        func rev(_ at: Int64, _ seq: Int) -> Revision {
            Revision(id: UUID(), pageID: page, seq: seq, createdAt: at, reason: "", contentHash: "", byteSize: 0)
        }
        let now = 100 * RevisionRetention.day
        let odd = [rev(Int64.min, 1), rev(Int64.max, 2), rev(-5, 3), rev(now - 1, 4)]
        for t in [now, Int64.min, Int64.max, 0] {
            let kept = RevisionRetention.keep(odd, now: t)
            check(!kept.isEmpty, "прореживание при now=\(t) не пусто")
        }
        let kept = RevisionRetention.keep(odd, now: now)
        check(kept.contains(odd[1].id), "дата в будущем считается свежей и не удаляется")
        check(kept.contains(odd[3].id), "свежий снимок остаётся")
    }

    await test("История: дата снимка из SQLite (min, max, отрицательная, будущая) — правка и снимок без аварии") {
        for (label, stored, expectNew) in [("Int64.min", Int64.min, true), ("Int64.max", Int64.max, true), ("отрицательная", Int64(-1), true),
                                           ("будущая", Int64(10_000_000_000), true), ("обычная, давняя", Int64(0), true),
                                           ("обычная, недавняя", Int64(-60_000), false)] {
            try await withTempDir { dir in
                let clock = FakeClock(), scheduler = ManualScheduler(clock: clock)
                clock.now = 1_000_000_000
                let root = dir.appendingPathComponent("w")
                let ws0 = try SQLiteWorkspace.create(at: root, name: "A")
                let session = WorkspaceSession(store: ws0, name: "A", scheduler: scheduler, clock: clock, ids: RandomIDs())
                let p = try await session.createPage(parent: nil, title: "Страница")
                var e = try await session.open(p.id)
                e.perform_(.setPlainText(block: e.document.blocks[0].id, text: "Первая"))
                try await e.snapshot(reason: "Проверка")
                try await session.close()
                ws0.close()
                // Открываем заново, как чужое пространство: дата снимка приходит из SQLite.
                let ws = try SQLiteWorkspace.open(at: root)
                // «Недавняя» задаётся относительно часов теста, остальные — как есть в базе.
                let value = label == "обычная, недавняя" ? clock.now + stored : stored
                try ws.maintenanceWrite { try $0.run("UPDATE revisions SET created_at=? WHERE page_id=?", [.int(value), SQLValue(p.id)]) }
                checkEqual(try await ws.revisions(ofPage: p.id).first?.createdAt, value, "\(label): дата прочитана из базы как есть")

                let again = WorkspaceSession(store: ws, name: "A", scheduler: scheduler, clock: clock, ids: RandomIDs())
                e = try await again.open(p.id)
                e.perform_(.setPlainText(block: e.document.blocks[0].id, text: "Вторая"))
                // Автоматический снимок запускается задачей: даём ей отработать.
                for _ in 0..<50 where try await ws.revisions(ofPage: p.id).count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
                let count = try await ws.revisions(ofPage: p.id).count
                checkEqual(count >= 2, expectNew, "\(label): автоматический снимок \(expectNew ? "сделан" : "не нужен")")
                try await e.snapshot(reason: "Ещё")
                let all = try await ws.revisions(ofPage: p.id)
                check(all.contains { $0.createdAt == value }, "\(label): прежний снимок не удалён")
                try await again.close()
            }
        }
    }

    await test("ИИ JSON: числа вне диапазона Int не вызывают аварии") {
        // Сам accessor.
        for raw in ["1e100", "-1e100", "1.5", "9223372036854775808", "1e19", "-1e19"] {
            checkEqual(JSONValue.parse(raw)?.intValue, nil, "\(raw) — не целое Int")
        }
        checkEqual(JSONValue.parse("9223372036854775807")?.intValue, Int.max, "верхняя граница")
        checkEqual(JSONValue.parse("-9223372036854775808")?.intValue, Int.min, "нижняя граница")
        checkEqual(JSONValue.parse("42")?.intValue, 42)
        checkEqual(JSONValue.parse("42.0")?.intValue, 42, "целое в виде Double")
        for v in [Double.nan, .infinity, -.infinity, 9.3e18, -9.3e18] { checkEqual(JSONValue.double(v).intValue, nil, "\(v)") }
        checkEqual(JSONValue.double(-0.0).intValue, 0)

        // SSE: недопустимый номер блока пропускает событие, обычный работает как прежде.
        for raw in ["1e100", "-1e100", "1.5", "-1", "9223372036854775807"] {
            let event = AIStreamParser.parse(line: "data: {\"type\":\"content_block_delta\",\"index\":\(raw),\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}")
            checkEqual(event, .unknown("content_block_delta/index"), "SSE index \(raw)")
        }
        checkEqual(AIStreamParser.parse(line: "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}"),
                   .textDelta(index: 2, text: "x"))
        checkEqual(AIStreamParser.parse(line: "data: {\"type\":\"content_block_stop\"}"), .blockStop(index: 0), "без index — 0, как прежде")

        // Usage: огромные и отрицательные счётчики не учитываются, обычные — как прежде.
        let start = AIStreamParser.parse(line: "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1e100,\"output_tokens\":-5,\"cache_read_input_tokens\":9223372036854775807,\"cache_creation_input_tokens\":7}}}")
        checkEqual(start, .messageStart(usage: AIUsage(input: 0, output: 0, cacheRead: 0, cacheWrite: 7)))
        var total = AIUsage(input: Int.max - 1, output: 3)
        total.add(AIUsage(input: 10, output: 4))
        checkEqual(total, AIUsage(input: Int.max, output: 7), "сумма без переполнения")

        // OpenAI-совместимый поток: usage и номер вызова инструмента.
        var acc = AIOpenAIAccumulator()
        acc.apply(chunk: JSONValue.parse("{\"usage\":{\"prompt_tokens\":1e100,\"completion_tokens\":12,\"prompt_tokens_details\":{\"cached_tokens\":-1e100}}}")!)
        checkEqual(acc.turn.usage.input, 0)
        checkEqual(acc.turn.usage.output, 12)
        checkEqual(acc.turn.usage.cacheRead, 0)
        acc.apply(chunk: JSONValue.parse("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1e100,\"id\":\"bad\",\"function\":{\"name\":\"search\",\"arguments\":\"{}\"}},{\"index\":0,\"id\":\"good\",\"function\":{\"name\":\"search\",\"arguments\":\"{\\\"query\\\":\\\"a\\\"}\"}}]}}]}")!)
        let ids = acc.turn.content.compactMap { $0["type"]?.stringValue == "tool_use" ? $0["id"]?.stringValue : nil }
        checkEqual(ids, ["good"], "вызов с недопустимым номером пропущен, обычный разобран")

        // Предел инструментов: огромное число не роняет разбор, действующие границы сохранены.
        func limit(_ raw: String, tool: String = "search") -> Int? {
            let extra = tool == "search" ? "\"query\":\"a\"" : "\"database_id\":\"\(UUID().uuidString.lowercased())\""
            guard let input = JSONValue.parse("{\(extra),\"limit\":\(raw)}") else { return nil }
            switch AITools.validate(name: tool, input: input) {
            case .success(.search(_, let l)), .success(.queryDatabase(_, let l)): return l
            default: return nil
            }
        }
        checkEqual(limit("5"), 5)
        checkEqual(limit("500"), 20, "верхняя граница поиска")
        checkEqual(limit("0"), 1, "нижняя граница поиска")
        for raw in ["1e100", "-1e100", "1.5"] { checkEqual(limit(raw), 8, "search limit \(raw): значение по умолчанию") }
        checkEqual(limit("1e100", tool: "query_database"), 50)
        checkEqual(limit("1000", tool: "query_database"), 200)
    }
}
