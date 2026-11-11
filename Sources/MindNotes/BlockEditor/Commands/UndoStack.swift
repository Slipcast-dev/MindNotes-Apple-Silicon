import Foundation

/// Стек отмены. Шаг хранит состояния затронутых блоков, поэтому структурная операция отменяется целиком.
struct UndoStack {
    struct Entry: Equatable {
        var forward: [BlockChange]
        var inverse: [BlockChange]
        var selectionBefore: BlockSelection?
        var selectionAfter: BlockSelection?
        var key: String?
        var time: Int64
    }

    /// Набор текста в одном блоке склеивается, пока паузы короче этого значения.
    static let coalesceWindow: Int64 = 1500
    static let limit = 500

    private(set) var undoEntries: [Entry] = []
    private(set) var redoEntries: [Entry] = []

    var canUndo: Bool { !undoEntries.isEmpty }
    var canRedo: Bool { !redoEntries.isEmpty }

    mutating func record(_ r: EditResult, selectionBefore: BlockSelection?, now: Int64) {
        guard !r.changes.isEmpty else { return }
        redoEntries = []
        if let key = r.coalesceKey, var last = undoEntries.last, last.key == key, now - last.time < Self.coalesceWindow {
            // Первое обратное состояние и последнее прямое: шаг возвращает текст к началу набора.
            last.forward = r.changes
            last.selectionAfter = r.selection
            last.time = now
            undoEntries[undoEntries.count - 1] = last
            return
        }
        undoEntries.append(Entry(forward: r.changes, inverse: r.inverse, selectionBefore: selectionBefore,
                                 selectionAfter: r.selection, key: r.coalesceKey, time: now))
        if undoEntries.count > Self.limit { undoEntries.removeFirst() }
    }

    mutating func popUndo() -> Entry? {
        guard let e = undoEntries.popLast() else { return nil }
        redoEntries.append(e)
        return e
    }

    mutating func popRedo() -> Entry? {
        guard let e = redoEntries.popLast() else { return nil }
        undoEntries.append(e)
        return e
    }
}
