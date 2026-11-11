import Foundation

/// Замок страницы (ADR-0017): пароль на страницу, запись, базу или папку. Это замок интерфейса, а не шифрование:
/// хранится только соль и производный ключ пароля. Замок предка закрывает и всё поддерево.
struct PageLock: Codable, Equatable {
    var page: UUID
    var salt: String       // base64
    var hash: String       // base64, PBKDF2-SHA256
    var rounds: Int

    static let metaKey = "ui.pageLocks"
    static let minPassword = 4

    static func decode(_ text: String?) -> [UUID: PageLock] {
        guard let text, let list = try? JSONDecoder().decode([PageLock].self, from: Data(text.utf8)) else { return [:] }
        var out: [UUID: PageLock] = [:]
        for lock in list where lock.rounds > 0 && !lock.salt.isEmpty && !lock.hash.isEmpty { out[lock.page] = lock }
        return out
    }

    static func encode(_ locks: [UUID: PageLock]) -> String {
        let list = locks.values.sorted { $0.page.uuidString < $1.page.uuidString }
        return String(decoding: (try? JSONEncoder().encode(list)) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// Ближайшая страница с замком: сама страница или предок. Цикл в данных не зацикливает поиск.
    static func lockingPage(of page: UUID, locked: Set<UUID>, parent: (UUID) -> UUID?) -> UUID? {
        var current: UUID? = page
        var seen: Set<UUID> = []
        while let id = current, seen.insert(id).inserted {
            if locked.contains(id) { return id }
            current = parent(id)
        }
        return nil
    }

    /// Закрыта ли страница сейчас: какой-то замок на пути к корню ещё не открыт.
    static func isClosed(_ page: UUID, locked: Set<UUID>, unlocked: Set<UUID>, parent: (UUID) -> UUID?) -> Bool {
        var current: UUID? = page
        var seen: Set<UUID> = []
        while let id = current, seen.insert(id).inserted {
            if locked.contains(id), !unlocked.contains(id) { return true }
            current = parent(id)
        }
        return false
    }
}
