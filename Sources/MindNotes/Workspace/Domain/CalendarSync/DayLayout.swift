import Foundation

/// Раскладка событий дня по колонкам: пересекающиеся события делят ширину, как в Календаре.
enum DayLayout {
    struct Slot: Equatable, Sendable {
        var index: Int
        /// Номер колонки внутри группы пересечений.
        var column: Int
        /// Сколько колонок в группе.
        var columns: Int
    }

    /// `intervals[i]` — начало и конец i-го события. Возвращает слоты в том же порядке.
    static func layout(_ intervals: [(start: Date, end: Date)]) -> [Slot] {
        let order = intervals.indices.sorted {
            let a = intervals[$0], b = intervals[$1]
            return a.start != b.start ? a.start < b.start : a.end > b.end
        }
        var result = [Slot?](repeating: nil, count: intervals.count)
        var cluster: [Int] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flush() {
            for i in cluster { result[i]?.columns = columnEnds.count }
            cluster.removeAll()
            columnEnds.removeAll()
        }

        for i in order {
            let iv = intervals[i]
            let end = max(iv.end, iv.start.addingTimeInterval(60))
            if !cluster.isEmpty && iv.start >= clusterEnd { flush(); clusterEnd = .distantPast }
            if let free = columnEnds.firstIndex(where: { $0 <= iv.start }) {
                columnEnds[free] = end
                result[i] = Slot(index: i, column: free, columns: 0)
            } else {
                columnEnds.append(end)
                result[i] = Slot(index: i, column: columnEnds.count - 1, columns: 0)
            }
            cluster.append(i)
            clusterEnd = max(clusterEnd, end)
        }
        flush()
        return result.compactMap { $0 }
    }
}
