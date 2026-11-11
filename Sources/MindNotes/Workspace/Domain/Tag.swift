import Foundation

/// Тег страницы. Имя уникально без учёта регистра.
struct Tag: Equatable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// Название цвета из палитры; nil — цвет по умолчанию.
    var color: String?

    /// Ключ сравнения имён: «Проект» и «проект» — один тег.
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}

/// Внешний вид пространства: логотип и обложка. Хранится в самом пространстве и переносится с архивом.
struct WorkspaceLook: Codable, Equatable {
    enum LogoKind: String, Codable { case symbol, emoji, image }
    enum CoverKind: String, Codable { case preset, image, none }

    var logoKind: LogoKind = .symbol
    /// Имя значка SF Symbols или emoji.
    var logoValue = "sparkle"
    /// Цвет плашки; nil — цвет темы.
    var logoColor: String?
    var logoAsset: UUID?
    var coverKind: CoverKind = .preset
    /// Название набора; nil — обложка темы.
    var coverPreset: String?
    var coverAsset: UUID?
    /// Подпись на обложке; nil — стандартная, пустая строка скрывает.
    var coverLabel: String?
}
