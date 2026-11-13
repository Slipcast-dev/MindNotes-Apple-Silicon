import Foundation

/// Нативная программа из выпуска плагина не запускается сама по одному лишь совпадению разрешений API
/// (аудит: автообновление плагина вне разрешений API).
func runNativeUpdateTests() async {
    await test("Плагины: автообновление с нативной программой — только от издателя приложения") {
        func manifest(_ version: String, repository: String? = nil, permissions: [String] = ["pages.create"]) -> PluginManifest {
            let repo = repository.map { #","repository":"\#($0)""# } ?? ""
            let json = #"{"id":"acme.clipper","name":"Clipper","version":"\#(version)","kind":"plugin","api":1,"permissions":[\#(permissions.map { "\"\($0)\"" }.joined(separator: ","))]\#(repo)}"#
            guard case .success(let m) = PluginManifest.parse(Data(json.utf8)) else { fatalError(json) }
            return m
        }
        let app = AppVersion("1.7.0"), owner = "Slipcast-dev"
        let own = manifest("1.0.0"), sibling = manifest("1.0.0", repository: "slipcast-dev/MindNotes-WebClipper")
        let third = manifest("1.0.0", repository: "acme/clipper")
        check(!own.nativeUpdateNeedsConsent(trustedOwner: owner), "репозиторий приложения")
        check(!sibling.nativeUpdateNeedsConsent(trustedOwner: owner), "отдельный репозиторий того же владельца (как у Web Clipper)")
        check(third.nativeUpdateNeedsConsent(trustedOwner: owner), "чужой владелец — сторонний издатель")
        check(manifest("1.0.0", repository: "Slipcast-dev-evil/x").nativeUpdateNeedsConsent(trustedOwner: owner), "похожее имя владельца")
        check(manifest("1.0.1").isAutomaticUpdate(of: own, app: app, trustedOwner: owner), "от издателя приложения ставится само")
        check(manifest("1.0.1", repository: "Slipcast-dev/MindNotes-WebClipper").isAutomaticUpdate(of: sibling, app: app, trustedOwner: owner),
              "Web Clipper из своего репозитория обновляется сам, как прежде")
        check(manifest("1.0.1", repository: "acme/clipper").isTrustedUpdate(of: third, app: app), "разрешения те же")
        check(!manifest("1.0.1", repository: "acme/clipper").isAutomaticUpdate(of: third, app: app, trustedOwner: owner),
              "сторонний выпуск с теми же разрешениями сам не ставится")
        check(!manifest("1.0.1", repository: "acme/clipper").isAutomaticUpdate(of: own, app: app, trustedOwner: owner), "переход к чужому репозиторию — с согласия")
        check(!manifest("1.0.1", permissions: ["pages.create", "tags.write"]).isAutomaticUpdate(of: own, app: app, trustedOwner: owner), "новое разрешение — с вопросом")
    }

    await test("Плагины: программа-установщик заменяет только саму себя") {
        let clipper = "local.personal.MindNotes.WebClipper"
        check(PluginInstallerPolicy.mayReplace(existing: clipper, new: clipper, expected: clipper), "та же программа")
        check(PluginInstallerPolicy.mayReplace(existing: nil, new: clipper, expected: clipper), "первая установка")
        check(!PluginInstallerPolicy.mayReplace(existing: clipper, new: "com.acme.installer", expected: nil), "чужой плагин не подменяет установщик Web Clipper")
        check(!PluginInstallerPolicy.mayReplace(existing: "local.personal.MindNotes", new: "com.acme.installer", expected: nil), "одноимённое чужое приложение не уходит в корзину")
        check(!PluginInstallerPolicy.mayReplace(existing: "", new: "com.acme.installer", expected: nil), "на месте что-то без bundle ID")
        check(!PluginInstallerPolicy.mayReplace(existing: nil, new: "com.acme.installer", expected: clipper), "ожидаемый bundle ID обязателен")
        check(!PluginInstallerPolicy.mayReplace(existing: nil, new: nil, expected: nil), "программа без bundle ID")
        check(PluginInstallerPolicy.mayReplace(existing: nil, new: "com.acme.installer", expected: nil), "сторонняя программа на свободное место")
    }
}

/// Адреса после DNS: обычное имя, указывающее в домашнюю сеть, не должно пропускать загрузку картинки.
func runClipAddressTests() async {
    await test("Web Clipper: публичность адресов после DNS") {
        for ip in ["93.184.216.34", "8.8.8.8", "1.1.1.1", "2606:4700:4700::1111", "2a00:1450:4001::200e", "::ffff:8.8.8.8"] {
            check(WebClip.isPublicAddress(ip), "публичный: \(ip)")
        }
        for ip in ["127.0.0.1", "10.0.0.5", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254", "100.64.0.1",
                   "0.0.0.0", "224.0.0.1", "255.255.255.255", "192.0.2.1", "198.18.0.1", "203.0.113.9", "198.51.100.7",
                   "::1", "::", "fe80::1", "fc00::1", "fd12:3456::1", "ff02::1", "2001:db8::1",
                   "::ffff:127.0.0.1", "::ffff:192.168.0.1", "64:ff9b::10.0.0.1", "::10.0.0.1", "", "не адрес", "1.2.3"] {
            check(!WebClip.isPublicAddress(ip), "не публичный: \(ip)")
        }
        check(WebClip.isPublicAddress("172.32.0.1") && WebClip.isPublicAddress("100.128.0.1"), "границы диапазонов")
    }
}

/// Замена приложения при обновлении: прежняя версия не теряется, если новая не встала на место.
func runUpdateReplacementTests() async {
    await test("Обновление: замена программы с откатом при сбое") {
        try await withTempDir { dir in
            let fm = FileManager.default
            // Уже завершившийся процесс: сценарий не ждёт.
            let done = Process()
            done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try done.run(); done.waitUntilExit()
            let pid = done.processIdentifier
            func app(_ url: URL, _ marker: String) throws {
                try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
                try Data(marker.utf8).write(to: url.appendingPathComponent("Contents/marker"))
            }
            func marker(_ url: URL) -> String? { (try? String(contentsOf: url.appendingPathComponent("Contents/marker"), encoding: .utf8)) }
            func run(_ script: String) throws -> Int32 {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", script]
                try p.run(); p.waitUntilExit()
                return p.terminationStatus
            }
            let current = dir.appendingPathComponent("Mind Notes's.app") // пробел и апостроф в пути
            let backup = dir.appendingPathComponent(".previous.app")

            // Успех: новая версия на месте, резервной копии не осталось.
            try app(current, "old")
            let staged = dir.appendingPathComponent(".update.app")
            try app(staged, "new")
            checkEqual(try run(UpdateReplacement.script(current: current, staged: staged, backup: backup, pid: pid, relaunch: false)), 0)
            checkEqual(marker(current), "new")
            check(!fm.fileExists(atPath: backup.path) && !fm.fileExists(atPath: staged.path), "временных копий нет")

            // Новой версии нет: установленная не тронута.
            let missing = try run(UpdateReplacement.script(current: current, staged: staged, backup: backup, pid: pid, relaunch: false))
            check(missing != 0)
            checkEqual(marker(current), "new", "прежняя версия на месте")

            // Перенос новой версии не удался (папка только для чтения): прежняя возвращается.
            let locked = dir.appendingPathComponent("ro")
            let stuck = locked.appendingPathComponent("update.app")
            try app(stuck, "newer")
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            let failed = try run(UpdateReplacement.script(current: current, staged: stuck, backup: backup, pid: pid, relaunch: false))
            check(failed != 0)
            checkEqual(marker(current), "new", "после сбоя прежняя версия восстановлена")
            check(!fm.fileExists(atPath: backup.path), "резервная копия вернулась на место")
        }
    }
}
