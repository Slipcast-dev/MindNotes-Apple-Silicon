import Foundation

/// Привязка клиентов: окно автоподключения не выдаёт ключ без согласия (аудит: plugin-auto-pair-authentication-bypass).
@MainActor
func runPairingTests() async {
    /// Тестовая обвязка вместо PluginHost: учитывает вопросы пользователю и выданные ключи.
    @MainActor final class Rig {
        let pairing = PluginPairing()
        var active: [String: Bool] = ["web": true]
        var windowOpen: Set<String> = []
        var answer = false
        var asked = 0
        var issued = 0

        func request(_ plugin: String = "web", origin: String? = "chrome-extension://untrusted-audit-extension", silent: Bool) -> LocalAPI.Request {
            var headers: [String: String] = [:]
            if let origin { headers["origin"] = origin }
            let body = try! JSONSerialization.data(withJSONObject: ["plugin": plugin, "silent": silent])
            return LocalAPI.Request(method: "POST", path: "/v1/pair", query: [:], headers: headers, body: body)
        }

        func send(_ r: LocalAPI.Request, now: Date = Date()) async -> LocalAPI.Response {
            await pairing.pair(r, now: now, isActive: { self.active[$0] }, isWindowOpen: { self.windowOpen.contains($0) },
                               closeWindow: { self.windowOpen.remove($0) },
                               ask: { _ in self.asked += 1; return self.answer },
                               issue: { _ in self.issued += 1; return .json(200, ["token": "t"]) })
        }

        func open() { windowOpen.insert("web"); pairing.windowOpened("web") }
    }

    await test("Привязка: чужой Origin в окне автоподключения не получает ключ без согласия") {
        let rig = Rig()
        rig.open()
        let reply = await rig.send(rig.request(silent: true))
        checkEqual(rig.asked, 1, "пользователю задан вопрос")
        checkEqual(rig.issued, 0, "ключ не выдан")
        checkEqual(reply.status, 403)
        check(!rig.windowOpen.contains("web"), "после отказа окно закрыто")
        // Повтор после отказа: ни вопроса, ни ключа.
        let again = await rig.send(rig.request(silent: true))
        checkEqual(rig.asked, 1, "повторный фоновый запрос вопрос не показывает")
        checkEqual(rig.issued, 0)
        check(again.status == 403 || again.status == 429, "отказ: \(again.status)")

        // Локальная программа с поддельным Origin или без него — тот же путь через согласие.
        let local = Rig()
        local.open()
        _ = await local.send(local.request(origin: nil, silent: false))
        _ = await local.send(local.request(origin: "chrome-extension://abcdef", silent: true))
        checkEqual(local.issued, 0, "без согласия ключа нет")
        check(local.asked >= 1, "решение за пользователем")
    }

    await test("Привязка: согласие пользователя подключает нового клиента") {
        let rig = Rig()
        rig.answer = true
        rig.open()
        let reply = await rig.send(rig.request(silent: true))
        checkEqual(reply.status, 200)
        checkEqual(rig.asked, 1)
        checkEqual(rig.issued, 1)
        // Обычная кнопка «Подключить» вне окна тоже спрашивает пользователя.
        let outside = Rig()
        outside.answer = true
        _ = await outside.send(outside.request(silent: false))
        checkEqual(outside.asked, 1)
        checkEqual(outside.issued, 1)
    }

    await test("Привязка: фоновые запросы не вызывают бесконечные вопросы") {
        let rig = Rig()
        rig.answer = true
        // Окно закрыто: фоновый запрос сразу отклоняется без вопроса.
        let closed = await rig.send(rig.request(silent: true))
        checkEqual(closed.status, 403)
        checkEqual(rig.asked, 0)
        rig.open()
        rig.answer = true
        for _ in 0..<5 { _ = await rig.send(rig.request(silent: true)) }
        checkEqual(rig.asked, 1, "один вопрос на источник за окно")
        for i in 0..<10 { _ = await rig.send(rig.request(origin: "chrome-extension://x\(i)", silent: true)) }
        checkEqual(rig.asked, PluginPairing.maxPromptsPerWindow, "общий предел вопросов за окно")
        checkEqual(rig.issued, rig.asked, "ключ — только на каждое согласие")

        // После отказа — пауза и для обычных запросов, новое окно от пользователя её снимает.
        let deny = Rig()
        let t0 = Date()
        _ = await deny.send(deny.request(silent: false), now: t0)
        let paused = await deny.send(deny.request(silent: false), now: t0.addingTimeInterval(5))
        checkEqual(paused.status, 429)
        checkEqual(deny.asked, 1, "в паузе вопрос не показан")
        _ = await deny.send(deny.request(silent: false), now: t0.addingTimeInterval(PluginPairing.cooldownAfterDenial + 1))
        checkEqual(deny.asked, 2, "после паузы снова можно спросить")
    }

    await test("Привязка: выключенный и неизвестный плагин") {
        let rig = Rig()
        rig.answer = true
        rig.active["web"] = false
        rig.open()
        checkEqual(await rig.send(rig.request(silent: false)).status, 403)
        checkEqual(await rig.send(rig.request("nope", silent: false)).status, 404)
        checkEqual(rig.asked, 0)
        checkEqual(rig.issued, 0)
        let bad = LocalAPI.Request(method: "POST", path: "/v1/pair", query: [:], headers: [:], body: Data("{}".utf8))
        checkEqual(await rig.send(bad).status, 400)
    }
}
