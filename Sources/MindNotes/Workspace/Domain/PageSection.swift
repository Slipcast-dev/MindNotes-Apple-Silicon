import Foundation

/// Свой раздел боковой панели (как «Страницы»), хранится в пространстве.
struct PageSection: Equatable, Identifiable {
    var id: UUID
    var name: String
    var sortKey: String

    static let maxName = 60

    /// Имя без пробелов по краям и не длиннее предела; пустое — nil.
    static func clean(_ name: String) -> String? {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(maxName))
    }
}
