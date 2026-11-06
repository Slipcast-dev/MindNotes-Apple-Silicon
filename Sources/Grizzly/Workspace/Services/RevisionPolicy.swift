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
