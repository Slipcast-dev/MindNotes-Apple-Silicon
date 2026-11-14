import Foundation

func runQuickAccessTests() async {
    await test("Быстрый доступ: места карточек, выбор и перестановка") {
        var s = QuickAccessSettings()
        checkEqual(s.count, 6)
        let a = UUID(), b = UUID(), c = UUID()
        s.setSlot(2, a)
        checkEqual(s.slots, [nil, nil, a], "страница встаёт ровно на выбранное место")
        s.setSlot(0, a)
        checkEqual(s.slots, [a], "та же страница на другом месте — прежнее освобождается")
        s.pin(b); s.pin(c); s.pin(b)
        checkEqual(s.slots, [a, b, c], "закрепление из меню страницы — первое свободное место")
        s.swapSlot(0, by: 1)
        checkEqual(s.slots, [b, a, c])
        s.swapSlot(0, by: -1)
        checkEqual(s.slots, [b, a, c], "за край не уходит")
        s.unpin(c)
        checkEqual(s.slots, [b, a])
        s.setSlot(1, nil)
        checkEqual(s.slots, [b], "пустые места в конце не хранятся")
        s.count = 9
        checkEqual(QuickAccessSettings(json: s.jsonString()), s)
        checkEqual(QuickAccessSettings(json: #"{"slots":[null],"count":5}"#).count, 6, "незнакомое число — по умолчанию")
        let dup = QuickAccessSettings(json: "{\"slots\":[\"\(a.uuidString)\",\"\(a.uuidString)\"],\"count\":3}")
        checkEqual(dup.slots, [a], "одна страница — одно место")
        checkEqual(QuickAccessSettings(json: "мусор"), QuickAccessSettings())
        var full = QuickAccessSettings()
        full.count = 3
        for _ in 0..<4 { full.pin(UUID()) }
        checkEqual(full.slots.count, 3, "все места заняты — замена последнего видимого")
    }

    await test("Быстрый доступ: частота с затуханием и выбор карточек") {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), gone = UUID()
        let day: Int64 = 24 * 3600 * 1000
        var stats: [UUID: OpenStat] = [:]
        // a — пять раз две недели назад, b — два раза сегодня: сейчас важнее b.
        for _ in 0..<5 { stats = OpenStats.bump(stats, page: a, now: 0) }
        for _ in 0..<2 { stats = OpenStats.bump(stats, page: b, now: 14 * day) }
        stats = OpenStats.bump(stats, page: gone, now: 14 * day)
        let now = 14 * day
        check(OpenStats.score(stats[b]!, now: now) > OpenStats.score(stats[a]!, now: now))
        check(abs(OpenStats.score(stats[a]!, now: now) - 1.25) < 0.001, "две недели — четверть веса")
        checkEqual(OpenStats.decode(OpenStats.encode(stats)), stats)

        var settings = QuickAccessSettings()
        settings.count = 3
        settings.setSlot(1, c)
        let picked = QuickAccess.pick(settings: settings, stats: stats, available: [a, b, c, d], fallback: [d, c], now: now)
        checkEqual(picked, [QuickSlot(page: b, pinned: false), QuickSlot(page: c, pinned: true), QuickSlot(page: a, pinned: false)],
                   "выбранная страница на своём месте, остальные — частые; страницы не из списка пропускаются")
        settings.count = 6
        checkEqual(QuickAccess.pick(settings: settings, stats: stats, available: [a, b, c, d], fallback: [d, c], now: now).map(\.page),
                   [b, c, a, d, nil, nil], "без истории — первые страницы верхнего уровня, дальше пустые места")
        settings.setSlot(0, gone)
        checkEqual(QuickAccess.pick(settings: settings, stats: [:], available: [c, d], fallback: [d], now: now).map(\.page), [d, c, nil, nil, nil, nil],
                   "выбранная страница в корзине — место заполняется само")

        var many: [UUID: OpenStat] = [:]
        for i in 0..<(OpenStats.maxEntries + 20) { many = OpenStats.bump(many, page: UUID(), now: Int64(i)) }
        checkEqual(many.count, OpenStats.maxEntries, "статистика не растёт без предела")
    }

    await test("Быстрый доступ: открытие страницы считается, настройки хранятся в пространстве") {
        try await withTempDir { dir in
            let w = try SQLiteWorkspace.create(at: dir.appendingPathComponent("w"), name: "T")
            defer { w.close() }
            let page = try await w.createPage(parent: nil, title: "Часто", id: UUID(), now: 1)
            try await w.markOpened(page.id, now: 10)
            try await w.markOpened(page.id, now: 10)
            let stats = try await w.openStats()
            checkEqual(stats[page.id]?.s, 2)
            checkEqual(try await w.allPages().first { $0.id == page.id }?.lastOpenedAt, 10)
            var settings = QuickAccessSettings()
            settings.setSlot(1, page.id)
            settings.count = 3
            try await w.setQuickAccess(settings)
            checkEqual(try await w.quickAccess(), settings)
        }
    }
}
