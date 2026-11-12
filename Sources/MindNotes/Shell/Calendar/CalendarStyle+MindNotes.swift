import SwiftUI

/// Оформление календаря внутри MindNotes: цвета и кнопки текущей темы (`Tokens`, `NotesButtonStyle`).
/// В MindNotes Calendar его роль играет `LabSupport/LabStyle.swift`. При переносе: `Shell/Calendar/`.
enum CalStyle {
    static var paper: Color { Tokens.paper }
    static var side: Color { Tokens.side }
    static var ink: Color { Tokens.ink }
    static var muted: Color { Tokens.muted }
    static var line: Color { Tokens.line }
    static var accent: Color { Tokens.accent }
    static var soft: Color { Tokens.soft }
    static var card: Color { Tokens.card }
    static var primary: Color { Tokens.primary }
    static var danger: Color { Tokens.danger }
    static func titleFont(_ size: CGFloat = 30) -> Font { Tokens.titleFont(size) }
}

typealias CalButtonStyle = NotesButtonStyle
