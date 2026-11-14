import Foundation

/// «Быстрый доступ» на главной: сначала закреплённые страницы в своём порядке,
/// свободные места — страницы, которые открывают чаще всего в последнее время.
/// Настройки и статистика хранятся в самом пространстве (`workspace_meta`) и переносятся с архивом.
struct QuickAccessSettings: Codable, Equatable {
    static let allowedCounts = [3, 6, 9]
    static let maxSlots = 9

    /// Места карточек по порядку: страница, выбранная пользователем, или nil — место заполняется само.
    var slots: [UUID?] = []
    var count = 6

    init() {}

    /// Испорченное или незнакомое значение даёт настройки по умолчанию.
    init(json: String?) {
        guard let data = json?.data(using: .utf8), let decoded = try? JSONDecoder().decode(QuickAccessSettings.self, from: data) else { return }
        self = decoded
        if !Self.allowedCounts.contains(count) { count = 6 }
        // Одна страница — одно место; лишние места отбрасываются.
        var seen = Set<UUID>()
        slots = Array(slots.prefix(Self.maxSlots)).map { id in id.flatMap { seen.insert($0).inserted ? $0 : nil } }
        trim()
    }

    func jsonString() -> String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }

    var pinned: [UUID] { slots.compactMap { $0 } }

    func isPinned(_ id: UUID) -> Bool { slots.contains(id) }

    func slot(of id: UUID) -> Int? { slots.firstIndex(of: id) }

    /// Поставить страницу на место `index` (nil — освободить место). Если страница уже стоит на другом месте, оно освобождается.
    mutating func setSlot(_ index: Int, _ id: UUID?) {
        guard index >= 0, index < Self.maxSlots else { return }
        if let id, let old = slots.firstIndex(of: id) { slots[old] = nil }
        while slots.count <= index { slots.append(nil) }
        slots[index] = id
        trim()
    }

    /// Закрепить на первом свободном месте среди видимых; все заняты — на последнее видимое.
    mutating func pin(_ id: UUID) {
        guard !isPinned(id) else { return }
        let free = (0..<count).first { $0 >= slots.count || slots[$0] == nil } ?? (count - 1)
        setSlot(free, id)
    }

    mutating func unpin(_ id: UUID) {
        if let i = slots.firstIndex(of: id) { slots[i] = nil }
        trim()
    }

    /// Поменять местами карточку на месте `index` с соседней (`delta` = -1 или 1).
    mutating func swapSlot(_ index: Int, by delta: Int) {
        let j = index + delta
        guard index >= 0, j >= 0, index < Self.maxSlots, j < Self.maxSlots else { return }
        while slots.count <= max(index, j) { slots.append(nil) }
        slots.swapAt(index, j)
        trim()
    }

    private mutating func trim() {
        while let last = slots.last, last == nil { slots.removeLast() }
    }
}

/// Частота открытия страницы с затуханием: открытие добавляет 1, старые открытия весят меньше
/// (период полураспада — неделя). Так наверх поднимается то, с чем работают сейчас, а не когда-то.
struct OpenStat: Codable, Equatable {
    var s: Double
    var t: Int64
}

enum OpenStats {
    static let halfLifeMs: Double = 7 * 24 * 3600 * 1000
    static let maxEntries = 300

    static func decode(_ json: String?) -> [UUID: OpenStat] {
        guard let data = json?.data(using: .utf8), let raw = try? JSONDecoder().decode([String: OpenStat].self, from: data) else { return [:] }
        var out: [UUID: OpenStat] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key), value.s.isFinite, value.s > 0 { out[id] = value }
        }
        return out
    }

    static func encode(_ stats: [UUID: OpenStat]) -> String {
        let raw = Dictionary(uniqueKeysWithValues: stats.map { ($0.key.uuidString, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: (try? encoder.encode(raw)) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// Вес на момент `now`.
    static func score(_ stat: OpenStat, now: Int64) -> Double {
        let age = max(0, Double(now - stat.t))
        return stat.s * pow(0.5, age / halfLifeMs)
    }

    /// Открытие страницы. Записей больше предела — уходят самые лёгкие.
    static func bump(_ stats: [UUID: OpenStat], page: UUID, now: Int64) -> [UUID: OpenStat] {
        var out = stats
        out[page] = OpenStat(s: (stats[page].map { score($0, now: now) } ?? 0) + 1, t: now)
        if out.count > maxEntries {
            let keep = out.sorted { score($0.value, now: now) > score($1.value, now: now) }.prefix(maxEntries)
            out = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return out
    }

    static func remove(_ stats: [UUID: OpenStat], pages: Set<UUID>) -> [UUID: OpenStat] {
        stats.filter { !pages.contains($0.key) }
    }
}

/// Карточка «Быстрого доступа»: страница и выбрана ли она пользователем. `page == nil` — пустое место.
struct QuickSlot: Equatable {
    var page: UUID?
    var pinned: Bool
}

enum QuickAccess {
    /// Карточки по местам. Выбранные пользователем стоят на своих местах; остальные места занимают частые страницы,
    /// без истории — первые страницы верхнего уровня (`fallback`). `available` — страницы, которые можно показать.
    /// Не хватило страниц — место пустое: на нём можно выбрать страницу.
    static func pick(settings: QuickAccessSettings, stats: [UUID: OpenStat], available: [UUID], fallback: [UUID], now: Int64) -> [QuickSlot] {
        let live = Set(available)
        var out: [QuickSlot] = (0..<settings.count).map { i in
            let id = i < settings.slots.count ? settings.slots[i] : nil
            return id.map { live.contains($0) ? QuickSlot(page: $0, pinned: true) : QuickSlot(page: nil, pinned: false) } ?? QuickSlot(page: nil, pinned: false)
        }
        var taken = Set(settings.pinned)
        let frequent = stats.filter { live.contains($0.key) && !taken.contains($0.key) }
            .sorted { a, b in
                let x = OpenStats.score(a.value, now: now), y = OpenStats.score(b.value, now: now)
                return x != y ? x > y : a.key.uuidString < b.key.uuidString
            }
            .map(\.key)
        var candidates = (frequent + fallback.filter { live.contains($0) }).makeIterator()
        for i in out.indices where out[i].page == nil {
            while let next = candidates.next() {
                if taken.insert(next).inserted { out[i] = QuickSlot(page: next, pinned: false); break }
            }
        }
        return out
    }
}
