import Foundation

enum SyntaxRole { case key, string, number, keyword, comment, error, warning, success, secondary }

/// Syntax scanner without any UI dependency: turns one line into colored ranges.
/// Config-like formats (JSON, YAML, ...) are matched with regular expressions per line. Programming languages
/// are first scanned for comments and strings, which may span lines (`/* */`, triple quotes, template literals):
/// the scanner state at the start of a line is carried over from the previous one (see `states`).
enum SyntaxEngine {
    struct Span { let range: NSRange; let role: SyntaxRole }

    private struct Rule {
        let regex: NSRegularExpression
        let role: SyntaxRole
        init(_ pattern: String, _ role: SyntaxRole, options: NSRegularExpression.Options = []) {
            self.regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.role = role
        }
    }

    private struct Block { let open: [UInt16]; let close: [UInt16]; let role: SyntaxRole
        init(_ open: String, _ close: String, _ role: SyntaxRole) { self.open = Array(open.utf16); self.close = Array(close.utf16); self.role = role }
    }

    private struct CodeLang {
        var lineComments: [[UInt16]] = []
        var blocks: [Block] = []
        var quotes: [UInt16] = []
        var rules: [Rule]
    }

    static let maxLength = 2000

    // MARK: Config-like formats

    private static let stringRule = Rule(#""(?:[^"\\]|\\.)*"|'[^']*'"#, .string)
    private static let numberRule = Rule(#"(?<![\w.])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?(?![\w.])"#, .number)

    private static let rules: [FileType: [Rule]] = [
        .json: [
            Rule(#""(?:[^"\\]|\\.)*"(?=\s*:)"#, .key),
            stringRule, numberRule,
            Rule(#"\b(?:true|false|null)\b"#, .keyword),
        ],
        .yaml: [
            Rule(#"(?:^|\s)#.*$"#, .comment),
            Rule(#"^\s*(?:-\s+)?(?:"[^"]*"|'[^']*'|[\w.\-/ ]+?)(?=:(?:\s|$))"#, .key),
            stringRule, numberRule,
            Rule(#"\b(?:true|false|null|yes|no|on|off)\b|(?<=\s)~(?=\s|$)"#, .keyword),
            Rule(#"^(?:---|\.\.\.)\s*$"#, .secondary),
            Rule(#"[&*]\w+|![\w!]+"#, .keyword),
        ],
        .config: [
            Rule(#"^\s*[;#].*$"#, .comment),
            Rule(#"^\s*\[[^\]]*\]"#, .keyword),
            Rule(#"^\s*[\w.\-"]+(?=\s*[=:])"#, .key),
            stringRule, numberRule,
            Rule(#"\b(?:true|false)\b"#, .keyword),
            Rule(#"\s[;#].*$"#, .comment),
        ],
        .xml: markup,
        .html: markup,
        .tex: [
            Rule(#"(?<!\\)%.*$"#, .comment),
            Rule(#"\$\$?[^$]*\$\$?"#, .string),
            Rule(#"\\(?:begin|end)\{[^}]*\}"#, .keyword),
            Rule(#"\\[A-Za-z]+\*?"#, .key),
            Rule(#"[{}\[\]]"#, .secondary),
        ],
        .log: [
            Rule(#"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?"#, .secondary),
            Rule(#"\b\d{2}:\d{2}:\d{2}(?:[.,]\d+)?\b"#, .secondary),
            Rule(#"\b(?:ERROR|ERR|FATAL|CRITICAL|SEVERE|PANIC|EXCEPTION|FAILED)\b"#, .error),
            Rule(#"\b(?:WARN|WARNING)\b"#, .warning),
            Rule(#"\b(?:INFO|NOTICE|SUCCESS|OK)\b"#, .success),
            Rule(#"\b(?:DEBUG|TRACE|VERBOSE)\b"#, .secondary),
            Rule(#"\[[^\]\n]{1,40}\]"#, .key),
        ],
    ]

    private static let markup: [Rule] = [
        Rule(#"<!--.*?-->|<!--.*$|^.*?-->"#, .comment),
        Rule(#""[^"]*"|'[^']*'"#, .string),
        Rule(#"<[!?/]?[A-Za-z][\w:\-.]*|<[!?]\w+"#, .keyword),
        Rule(#"[\w:\-.]+(?==)"#, .key),
        Rule(#"/?\??>"#, .keyword),
        Rule(#"&\w+;|&#\d+;"#, .number),
    ]

    // MARK: Programming languages

    private static func words(_ list: String, _ role: SyntaxRole) -> Rule {
        Rule(#"\b(?:"# + list.split(separator: " ").joined(separator: "|") + #")\b"#, role)
    }

    private static let codeNumber = Rule(#"\b(?:0[xX][0-9A-Fa-f_]+|0[bB][01_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)[uUlLfFdDmMzZ]*\b"#, .number)
    private static let typeName = Rule(#"\b[A-Z][A-Za-z0-9_]*\b"#, .key)
    private static let slashComments: [[UInt16]] = [Array("//".utf16)]
    private static let cBlock = Block("/*", "*/", .comment)
    private static let quotes2: [UInt16] = [34, 39]          // " '
    private static let quotes3: [UInt16] = [34, 39, 96]      // " ' `

    private static let codeLangs: [FileType: CodeLang] = [
        .python: CodeLang(
            lineComments: [Array("#".utf16)],
            blocks: [Block("\"\"\"", "\"\"\"", .string), Block("'''", "'''", .string)],
            quotes: quotes2,
            rules: [
                Rule(#"^\s*@[\w.]+|(?<=\s)@[\w.]+$"#, .key),
                words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case", .keyword),
                words("True False None self cls", .number),
                codeNumber, typeName,
            ]),
        .swift: CodeLang(
            lineComments: slashComments,
            blocks: [Block("\"\"\"", "\"\"\"", .string), cBlock],
            quotes: [34],
            rules: [
                Rule(#"@\w+|#\w+"#, .key),
                words("actor associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough fileprivate final for func guard if import in indirect init inout internal is lazy let mutating nonisolated nonmutating open operator override private protocol public repeat rethrows return static struct subscript super switch throw throws try typealias var weak where while some any willSet didSet get set self Self", .keyword),
                words("true false nil", .number),
                codeNumber, typeName,
            ]),
        .cpp: CodeLang(
            lineComments: slashComments,
            blocks: [cBlock],
            quotes: quotes2,
            rules: [
                Rule(#"^\s*#\s*\w+"#, .keyword),
                Rule(#"(?<=include )<[^>]*>|(?<=include)<[^>]*>"#, .string),
                words("alignas alignof auto bool break case catch char class concept const consteval constexpr const_cast continue co_await co_return co_yield decltype default delete do double dynamic_cast else enum explicit extern final float for friend goto if inline int long mutable namespace new noexcept operator override private protected public register reinterpret_cast requires return short signed sizeof static static_assert static_cast struct switch template this thread_local throw try typedef typeid typename union unsigned using virtual void volatile while", .keyword),
                words("true false NULL nullptr", .number),
                codeNumber, typeName,
            ]),
        .csharp: CodeLang(
            lineComments: slashComments,
            blocks: [cBlock],
            quotes: quotes2,
            rules: [
                Rule(#"^\s*#\s*\w+"#, .keyword),
                words("abstract as async await base bool break byte case catch char checked class const continue decimal default delegate do double dynamic else enum event explicit extern finally fixed float for foreach get goto if implicit in init int interface internal is lock long nameof namespace new object operator out override params partial private protected public readonly record ref required return sbyte sealed set short sizeof stackalloc static string struct switch this throw try typeof uint ulong unchecked unsafe ushort using var virtual void volatile when where while with yield", .keyword),
                words("true false null", .number),
                codeNumber, typeName,
            ]),
        .javascript: CodeLang(
            lineComments: slashComments,
            blocks: [Block("`", "`", .string), cBlock],
            quotes: [34, 39],
            rules: jsRules(extra: "")),
        .typescript: CodeLang(
            lineComments: slashComments,
            blocks: [Block("`", "`", .string), cBlock],
            quotes: [34, 39],
            rules: jsRules(extra: "abstract any as asserts bigint boolean declare enum implements infer interface is keyof module namespace never number object override private protected public readonly satisfies string symbol type unknown")),
        .css: CodeLang(
            lineComments: [],
            blocks: [cBlock],
            quotes: quotes2,
            rules: [
                Rule(#"@[\w-]+"#, .keyword),
                Rule(#"!important"#, .error),
                Rule(#"^\s*[\w-]+(?=\s*:\s*[^;{]*[;}]?\s*$)"#, .key),
                Rule(#"(?<=[:\s,(])#[0-9a-fA-F]{3,8}\b"#, .number),
                Rule(#"(?<![\w-])-?(?:\d+\.?\d*|\.\d+)(?:px|em|rem|%|vh|vw|vmin|vmax|ch|ex|pt|cm|mm|in|s|ms|deg|rad|turn|fr)?(?![\w-])"#, .number),
                Rule(#"[\w-]+(?=\()"#, .key),
                Rule(#"::?[a-zA-Z-]+(?![\w-]*\s*:\s)"#, .keyword),
                Rule(#"[.#][A-Za-z_][\w-]*"#, .keyword),
            ]),
        .php: CodeLang(
            lineComments: [Array("//".utf16), Array("#".utf16)],
            blocks: [cBlock],
            quotes: quotes2,
            rules: [
                Rule(#"<\?php|<\?=|\?>"#, .keyword),
                Rule(#"\$\w+"#, .key),
                words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield", .keyword),
                Rule(#"\b(?:true|false|null|TRUE|FALSE|NULL)\b"#, .number),
                codeNumber, typeName,
            ]),
    ]

    private static func jsRules(extra: String) -> [Rule] {
        [
            Rule(#"@\w+"#, .key),
            words("async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield " + extra, .keyword),
            words("true false null undefined NaN Infinity", .number),
            codeNumber, typeName,
        ]
    }

    // MARK: API

    static func hasHighlighting(_ type: FileType) -> Bool { rules[type] != nil || codeLangs[type] != nil }

    /// True for languages whose comments or strings can span lines.
    static func isStateful(_ type: FileType) -> Bool { codeLangs[type] != nil }

    /// The scanner state at the start of every line (0 = nothing open); empty for formats without carried state.
    static func states(_ lines: [String], type: FileType) -> [Int] {
        guard let lang = codeLangs[type] else { return [] }
        var out = [Int](); out.reserveCapacity(lines.count)
        var state = 0
        for line in lines {
            out.append(state)
            state = scan(Array(line.utf16), lang, state).next
        }
        return out
    }

    static func spans(_ line: String, type: FileType, state: Int = 0) -> (spans: [Span], next: Int) {
        let u = Array(line.utf16)
        var spans: [Span] = []
        var next = 0
        var ruleList: [Rule]
        var claimed = [Bool](repeating: false, count: u.count)

        if let lang = codeLangs[type] {
            let scanned = scan(u, lang, state)
            next = scanned.next
            guard u.count <= maxLength, !u.isEmpty else { return ([], next) }
            for s in scanned.spans {
                for k in s.range.location..<(s.range.location + s.range.length) { claimed[k] = true }
            }
            spans = scanned.spans
            ruleList = lang.rules
        } else if let list = rules[type] {
            guard u.count <= maxLength, !u.isEmpty else { return ([], 0) }
            ruleList = list
        } else {
            return ([], 0)
        }

        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        for rule in ruleList {
            rule.regex.enumerateMatches(in: line, options: [], range: full) { match, _, _ in
                guard let r = match?.range, r.length > 0 else { return }
                // A character claimed by an earlier rule is never recolored: color only the free runs.
                var runStart: Int?
                for i in r.location...(r.location + r.length) {
                    let free = i < r.location + r.length && !claimed[i]
                    if free, runStart == nil { runStart = i }
                    if !free, let s = runStart {
                        spans.append(Span(range: NSRange(location: s, length: i - s), role: rule.role))
                        for k in s..<i { claimed[k] = true }
                        runStart = nil
                    }
                }
            }
        }
        return (spans, next)
    }

    // MARK: Scanner

    private static func scan(_ u: [UInt16], _ lang: CodeLang, _ start: Int) -> (spans: [Span], next: Int) {
        var spans: [Span] = []
        var state = start
        var i = 0
        let n = u.count

        func matches(_ pattern: [UInt16], _ at: Int) -> Bool {
            guard !pattern.isEmpty, at + pattern.count <= n else { return false }
            for k in 0..<pattern.count where u[at + k] != pattern[k] { return false }
            return true
        }
        func find(_ pattern: [UInt16], from: Int, escapes: Bool) -> Int? {
            var j = from
            while j + pattern.count <= n {
                if escapes && u[j] == 92 { j += 2; continue }
                if matches(pattern, j) { return j }
                j += 1
            }
            return nil
        }
        func add(_ from: Int, _ to: Int, _ role: SyntaxRole) {
            if to > from { spans.append(Span(range: NSRange(location: from, length: to - from), role: role)) }
        }

        while i < n {
            if state > 0 {
                let b = lang.blocks[state - 1]
                if let e = find(b.close, from: i, escapes: b.role == .string) {
                    add(i, e + b.close.count, b.role)
                    i = e + b.close.count
                    state = 0
                } else {
                    add(i, n, b.role)
                    i = n
                }
                continue
            }
            if let bi = lang.blocks.firstIndex(where: { matches($0.open, i) }) {
                let b = lang.blocks[bi]
                let from = i
                i += b.open.count
                if let e = find(b.close, from: i, escapes: b.role == .string) {
                    i = e + b.close.count
                    add(from, i, b.role)
                } else {
                    add(from, n, b.role)
                    i = n
                    state = bi + 1
                }
                continue
            }
            if lang.lineComments.contains(where: { matches($0, i) }) {
                add(i, n, .comment)
                break
            }
            if lang.quotes.contains(u[i]) {
                let q = u[i]
                var j = i + 1
                while j < n && u[j] != q { j += u[j] == 92 ? 2 : 1 }
                let end = min(j + 1, n)
                add(i, end, .string)
                i = end
                continue
            }
            i += 1
        }
        return (spans, state)
    }
}
