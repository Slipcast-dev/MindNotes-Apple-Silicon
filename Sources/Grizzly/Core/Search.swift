import SwiftUI

/// One hit. `unit` is the row the hit lives in (a source line or a Markdown block),
/// `occurrence` counts hits inside that unit in display order.
struct SearchMatch: Equatable {
    let unit: Int
    let occurrence: Int
}

/// What a view needs to paint matches: the query plus the hit that is currently selected.
struct SearchHighlight {
    let query: String
    let current: SearchMatch?
}

struct ScrollTarget: Equatable {
    let unit: Int
    let id = UUID()
}

enum Searcher {
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let r = text.range(of: query, options: [.caseInsensitive], range: start..<text.endIndex) {
            result.append(r)
            start = r.upperBound > r.lowerBound ? r.upperBound : text.index(after: start)
        }
        return result
    }

    /// Hits in plain lines (the text being edited), one unit per line.
    static func matches(query: String, inLines lines: [String]) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        var result: [SearchMatch] = []
        for (i, line) in lines.enumerated() {
            for k in ranges(of: query, in: line).indices { result.append(SearchMatch(unit: i, occurrence: k)) }
        }
        return result
    }

    /// File and folder names: every word typed has to be the beginning of the name or of one of its words,
    /// so "гриз", "read me" and "me" all find "Read Me.md".
    static func nameMatches(_ name: String, query: String) -> Bool {
        let typed = query.split { $0.isWhitespace }.map(String.init)
        guard !typed.isEmpty else { return true }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let words = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return typed.allSatisfy { t in
            name.range(of: t, options: opts.union(.anchored)) != nil
                || words.contains { $0.range(of: t, options: opts.union(.anchored)) != nil }
        }
    }
}

extension AttributedString {
    func highlighted(_ highlight: SearchHighlight?, unit: Int, offset: Int, theme: Theme) -> AttributedString {
        guard let highlight, !highlight.query.isEmpty else { return self }
        let plain = String(characters)
        let found = Searcher.ranges(of: highlight.query, in: plain)
        guard !found.isEmpty else { return self }

        var out = self
        for (k, r) in found.enumerated() {
            let lo = plain.distance(from: plain.startIndex, to: r.lowerBound)
            let hi = plain.distance(from: plain.startIndex, to: r.upperBound)
            let a = out.characters.index(out.startIndex, offsetBy: lo)
            let b = out.characters.index(out.startIndex, offsetBy: hi)
            let isCurrent = highlight.current == SearchMatch(unit: unit, occurrence: offset + k)
            out[a..<b].backgroundColor = isCurrent ? theme.currentMatch : theme.match
            if isCurrent { out[a..<b].foregroundColor = .black }
        }
        return out
    }
}
