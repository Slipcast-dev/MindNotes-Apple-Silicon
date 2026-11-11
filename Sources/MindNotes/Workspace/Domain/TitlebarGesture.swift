import Foundation

/// Двойной щелчок по верхней полосе окна (заголовок и панель): что сделать, как в настройках macOS.
/// Элементы панели SwiftUI перехватывают щелчок, и система сама окно не разворачивает — решает это правило.
enum TitlebarGesture: Equatable {
    case zoom, minimize, none

    /// `AppleActionOnDoubleClick` из общих настроек: «Maximize»/«Fill» — развернуть, «Minimize» — свернуть в Dock, «None» — ничего.
    /// Старый ключ `AppleMiniaturizeOnDoubleClick` тоже учитывается. Нет настройки — развернуть (как в macOS по умолчанию).
    static func action(preference: String?, legacyMinimize: Bool) -> TitlebarGesture {
        switch preference {
        case "Minimize"?: return .minimize
        case "None"?: return .none
        case "Maximize"?, "Fill"?, "Zoom"?: return .zoom
        default: return legacyMinimize ? .minimize : .zoom
        }
    }

    /// Щелчок пришёлся на полосу заголовка: выше области содержимого и не на кнопку справа (переключатель темы).
    /// Координаты окна — от нижнего края, как в AppKit.
    static func isTitlebar(x: Double, y: Double, windowWidth: Double, contentTop: Double, trailingControls: Double = 72) -> Bool {
        y >= contentTop && x >= 0 && x <= windowWidth - trailingControls
    }
}
