import SwiftUI

/// Colors for `SyntaxEngine` output. One line = one unit, so search and bookmarks are unaffected;
/// `state` is the scanner state at the start of the line (see `Document.syntaxStates`).
enum Syntax {
    static func hasHighlighting(_ type: FileType) -> Bool { SyntaxEngine.hasHighlighting(type) }

    static func highlight(_ line: String, type: FileType, theme: Theme, state: Int = 0) -> AttributedString {
        var out = AttributedString(line)
        guard Preferences.shared.highlights(type) else { return out }
        let spans = SyntaxEngine.spans(line, type: type, state: state).spans
        for span in spans {
            guard let r = Range(span.range, in: line) else { continue }
            let lo = line.distance(from: line.startIndex, to: r.lowerBound)
            let hi = line.distance(from: line.startIndex, to: r.upperBound)
            let a = out.characters.index(out.startIndex, offsetBy: lo)
            let b = out.characters.index(out.startIndex, offsetBy: hi)
            out[a..<b].foregroundColor = color(span.role, theme)
        }
        return out
    }

    /// A multi-line code block (Markdown fence) colored as one string; `\n` joins the lines.
    static func highlightBlock(_ code: String, type: FileType, theme: Theme) -> AttributedString {
        guard Preferences.shared.highlights(type) else { return AttributedString(code) }
        let lines = code.components(separatedBy: "\n")
        let states = SyntaxEngine.states(lines, type: type)
        var out = AttributedString()
        for (i, line) in lines.enumerated() {
            if i > 0 { out += AttributedString("\n") }
            out += highlight(line, type: type, theme: theme, state: states.isEmpty ? 0 : states[i])
        }
        return out
    }

    static func color(_ role: SyntaxRole, _ t: Theme) -> Color {
        switch role {
        case .key: return t.key
        case .string: return t.string
        case .number: return t.number
        case .keyword: return t.keyword
        case .comment, .secondary: return t.comment
        case .error: return t.error
        case .warning: return t.warning
        case .success: return t.success
        }
    }
}
