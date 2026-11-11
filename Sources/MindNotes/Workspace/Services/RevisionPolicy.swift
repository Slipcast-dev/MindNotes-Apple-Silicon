import Foundation

/// Частота контрольных снимков. История — не журнал каждого символа (FR-07.8).
struct RevisionPolicy {
    static let minInterval: Int64 = 10 * 60 * 1000

    /// Снимок нужен, если есть изменения с прошлого снимка и прошло достаточно времени.
    func isDue(dirty: Bool, lastSnapshotAt: Int64?, now: Int64) -> Bool {
        guard dirty else { return false }
        guard let last = lastSnapshotAt else { return true }
        return now - last >= Self.minInterval
    }
}

/// Удержание снимков: за сутки всё, за неделю один в час, за 30 дней один в день, дальше один в неделю.
/// Самый новый снимок остаётся всегда; старая история прореживается, но не исчезает целиком.
enum RevisionRetention {
    static let hour: Int64 = 3_600_000
    static let day: Int64 = 24 * hour

    static func keep(_ revisions: [Revision], now: Int64) -> Set<UUID> {
        var kept: Set<UUID> = []
        var buckets: [String: Revision] = [:]
        for revision in revisions {
            let age = now - revision.createdAt
            let bucket: String
            if age < day { kept.insert(revision.id); continue }
            else if age < 7 * day { bucket = "h\(revision.createdAt / hour)" }
            else if age < 30 * day { bucket = "d\(revision.createdAt / day)" }
            else { bucket = "w\(revision.createdAt / (7 * day))" }
            if let other = buckets[bucket], (other.createdAt, other.seq) >= (revision.createdAt, revision.seq) { continue }
            buckets[bucket] = revision
        }
        kept.formUnion(buckets.values.map(\.id))
        if let newest = revisions.max(by: { ($0.createdAt, $0.seq) < ($1.createdAt, $1.seq) }) { kept.insert(newest.id) }
        return kept
    }
}
