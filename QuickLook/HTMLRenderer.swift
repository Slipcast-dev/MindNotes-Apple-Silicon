import Foundation

/// Turns parsed documents into self-contained HTML for the Quick Look preview.
enum HTMLRenderer {
    static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        :root { color-scheme: light dark; }
        body { font: 15px/1.55 -apple-system, "Helvetica Neue", sans-serif; margin: 22px 28px; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.2em 0 .4em; }
        h1 { font-size: 1.8em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; }
        pre, code { font: 13px/1.5 ui-monospace, Menlo, monospace; }
        pre { background: rgba(127,127,127,.14); padding: 12px 14px; border-radius: 8px; overflow-x: auto; white-space: pre-wrap; word-break: break-word; }
        code { background: rgba(127,127,127,.18); padding: 1px 4px; border-radius: 4px; }
        pre code { background: none; padding: 0; }
        blockquote { margin: .8em 0; padding: 0 1em; border-left: 3px solid rgba(127,127,127,.5); opacity: .85; }
        hr { border: 0; border-top: 1px solid rgba(127,127,127,.4); }
        table { border-collapse: collapse; margin: .8em 0; }
        th, td { border: 1px solid rgba(127,127,127,.35); padding: 4px 10px; text-align: left; vertical-align: top; }
        th { background: rgba(127,127,127,.15); }
        .plain { margin: 0; padding: 0; background: none; }
        mark { color: inherit; border-radius: 3px; padding: 0 2px; }
        mark.violet { background: rgba(179,157,255,.45); } mark.pink { background: rgba(255,158,196,.45); }
        mark.orange { background: rgba(255,176,112,.45); } mark.mint { background: rgba(143,227,192,.45); }
        mark.blue { background: rgba(142,197,255,.45); }
        .note { opacity: .6; font-size: 12px; margin-top: 18px; }
        </style></head><body>\(body)</body></html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Only web and mail links stay clickable; `javascript:`, `file:` and relative targets become plain text.
    static func isSafeLink(_ target: String) -> Bool {
        let lower = target.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:")
    }

    /// Replaces `[text](target)` in already escaped text with anchors (safe targets only).
    private static func links(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)") else { return s }
        var out = s
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let label = ns.substring(with: m.range(at: 1))
            let target = ns.substring(with: m.range(at: 2))
            // `escape` ran first, so a target cannot contain a raw quote or angle bracket.
            let html = isSafeLink(target) ? "<a href=\"\(target)\">\(label)</a>" : label
            out = (out as NSString).replacingCharacters(in: m.range, with: html)
        }
        return out
    }

    static func code(_ lines: [String]) -> String {
        "<pre class=\"plain\">\(escape(lines.joined(separator: "\n")))</pre>"
    }

    static func csv(url: URL, lines: [String]) -> String {
        let table = CSVTable(lines: lines, delimiter: CSVTable.detectDelimiter(url: url, lines: lines))
        var out = "<table>"
        for (i, row) in table.rows.prefix(2000).enumerated() {
            let tag = i == 0 ? "th" : "td"
            out += "<tr>" + row.cells.map { "<\(tag)>\(escape($0))</\(tag)>" }.joined() + "</tr>"
        }
        return out + "</table>"
    }

    static func markdown(_ lines: [String]) -> String {
        var out = ""
        for block in MarkdownParser.parse(lines) { out += render(block) }
        return out
    }

    private static func render(_ block: MDBlock) -> String {
        var out = ""
        switch block {
        case .aligned(let align, let inner):
            out += "<div style=\"text-align:\(align.rawValue)\">" + render(inner) + "</div>"
        case .heading(let level, let text):
            let n = min(max(level, 1), 6)
            out += "<h\(n)>\(inline(text))</h\(n)>"
        case .paragraph(let text): out += "<p>\(inline(text))</p>"
        case .bullets(let items): out += "<ul>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ul>"
        case .dashes(let items): out += "<ul style=\"list-style-type:'– '\">" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ul>"
        case .tasks(let items):
            out += "<ul style=\"list-style:none;padding-left:4px\">" + items.map {
                "<li>\($0.done ? "&#9679;" : "&#9675;") \($0.done ? "<s>\(inline($0.text))</s>" : inline($0.text))</li>"
            }.joined() + "</ul>"
        case .numbered(let items): out += "<ol>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ol>"
        case .code(_, let body): out += "<pre><code>\(escape(body))</code></pre>"
        case .quote(let text): out += "<blockquote>\(inline(text))</blockquote>"
        case .rule: out += "<hr>"
        case .table(let header, let rows):
            out += "<table><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr>"
            for r in rows { out += "<tr>" + r.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }
            out += "</table>"
        }
        return out
    }

    /// Escapes the text, then applies the common inline markup (code, bold, italic, links).
    private static func inline(_ text: String) -> String {
        var s = escape(text)
        let rules: [(String, String)] = [
            ("`([^`]+)`", "<code>$1</code>"),
            ("\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>"),
            ("(?<![*\\w])\\*([^*\\n]+)\\*(?!\\w)", "<em>$1</em>"),
            ("~~([^~]+)~~", "<s>$1</s>"),
            // The tags were escaped above; the few Grizzly writes itself are turned back.
            ("&lt;u&gt;(.*?)&lt;/u&gt;", "<u>$1</u>"),
            ("&lt;mark class=&quot;(violet|pink|orange|mint|blue)&quot;&gt;(.*?)&lt;/mark&gt;", "<mark class=\"$1\">$2</mark>"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return links(s)
    }
}
