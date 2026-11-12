import Foundation

/// Строит план сверки «приложение ↔ Календарь». Чистая функция: ничего не читает и не пишет,
/// поэтому вся логика синхронизации проверяется тестами без EventKit.
enum SyncPlanner {

    /// - Parameters:
    ///   - local: элементы приложения одного вида (`kind`).
    ///   - remote: элементы из календаря или списка приложения, плюс найденные по id связанные элементы вне окна.
    ///   - window: окно выборки из Календаря. Элемент со сроком вне окна не считается удалённым,
    ///     даже если его нет в `remote`. `nil` — выборка полная: всё, чего нет, удалено.
    static func plan(local: [LocalItem], remote: [RemoteItem], policy: ConflictPolicy,
                     window: DateInterval?) -> [SyncAction] {
        var byExternal: [String: RemoteItem] = [:]
        var byApp: [UUID: RemoteItem] = [:]
        for r in remote {
            byExternal[r.externalID] = r
            if let a = r.appID { byApp[a] = r }
        }
        let knownIDs = Set(local.map(\.id))
        // Без url (стёрт или элемент старый) пару можно найти только по содержимому.
        var orphans = remote.filter { r in
            r.appID.map { !knownIDs.contains($0) } ?? true
        }.filter { r in !local.contains { $0.externalID == r.externalID } }
        var matched = Set<String>()
        var actions: [SyncAction] = []

        for item in local {
            // Найти пару: по идентификатору EventKit, по своему UUID в url, затем по содержимому.
            var pair: RemoteItem?
            if let ext = item.externalID, let r = byExternal[ext] {
                pair = r
            } else if let r = byApp[item.id] {
                pair = r
                if item.syncEnabled && !item.isDeleted { actions.append(.relink(item.id, externalID: r.externalID)) }
            } else if item.syncEnabled && !item.isDeleted,
                      let i = orphans.firstIndex(where: { $0.kind == item.kind && $0.fields.looksLike(item.fields) }) {
                let r = orphans.remove(at: i)
                pair = r
                actions.append(.relink(item.id, externalID: r.externalID))
            }
            if let p = pair { matched.insert(p.externalID); orphans.removeAll { $0.externalID == p.externalID } }
            guard item.syncEnabled else { continue }

            if item.isDeleted {
                if let p = pair { actions.append(.pushDelete(item.id, externalID: p.externalID)) }
                continue
            }

            guard let r = pair else {
                if item.externalID == nil {
                    actions.append(.pushCreate(item.id))
                } else if inWindow(item.fields.start, window) {
                    actions.append(.pullDelete(item.id))
                }
                continue
            }

            if item.fields.sameContent(as: r.fields) {
                // Пара найдена без своего url (стёрт или не записан): записать его заново.
                if r.appID != item.id { actions.append(.pushUpdate(item.id)); continue }
                if item.syncedAt == nil || item.externalID != r.externalID || r.modifiedAt > (item.syncedAt ?? .distantPast) {
                    actions.append(.markSynced(item.id, modifiedAt: r.modifiedAt))
                }
                continue
            }

            let since = item.syncedAt ?? .distantPast
            let localChanged = item.syncedAt == nil || item.updatedAt > since
            let remoteChanged = item.syncedAt == nil || r.modifiedAt > since

            switch (localChanged, remoteChanged) {
            case (true, false):
                actions.append(.pushUpdate(item.id))
            case (false, true):
                actions.append(.pullUpdate(item.id, r))
            case (false, false):
                // Содержимое разное, но даты не сдвинулись (например, правка часов на Mac). Приложение главнее.
                actions.append(.pushUpdate(item.id))
            case (true, true):
                switch policy {
                case .ask: actions.append(.conflict(item.id, r))
                case .appWins: actions.append(.pushUpdate(item.id))
                case .newerWins:
                    actions.append(item.updatedAt >= r.modifiedAt ? .pushUpdate(item.id) : .pullUpdate(item.id, r))
                }
            }
        }

        for r in remote where !matched.contains(r.externalID) {
            // Элемент с известным приложению UUID не воскрешаем: его синхронизация выключена или он удалён.
            if let a = r.appID, knownIDs.contains(a) { continue }
            actions.append(.importNew(r))
        }
        return actions
    }

    /// Связанные элементы, которых нет в выборке окна: их надо поискать по id, прежде чем считать удалёнными.
    static func needsLookup(local: [LocalItem], fetched: [RemoteItem]) -> [String] {
        let have = Set(fetched.map(\.externalID))
        return local.compactMap { item in
            guard item.syncEnabled, let ext = item.externalID, !have.contains(ext) else { return nil }
            return ext
        }
    }

    private static func inWindow(_ date: Date?, _ window: DateInterval?) -> Bool {
        guard let window else { return true }
        guard let date else { return true }
        return window.contains(date)
    }
}
