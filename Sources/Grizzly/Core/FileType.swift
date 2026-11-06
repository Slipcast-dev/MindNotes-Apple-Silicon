import Foundation

enum FileType: String, CaseIterable {
    case markdown, text, json, yaml, csv, log, xml, html, config, tex, rtf
    case python, swift, cpp, csharp, javascript, typescript, css, php

    static let extensions: [String: FileType] = [
        "md": .markdown, "markdown": .markdown, "mdown": .markdown,
        "txt": .text, "text": .text,
        "json": .json,
        "yaml": .yaml, "yml": .yaml,
        "csv": .csv, "tsv": .csv,
        "log": .log,
        "xml": .xml,
        "html": .html, "htm": .html,
        "ini": .config, "conf": .config, "toml": .config,
        "tex": .tex,
        "rtf": .rtf,
        "py": .python, "pyw": .python,
        "swift": .swift,
        "c": .cpp, "h": .cpp, "cpp": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp,
        "cs": .csharp,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "tsx": .typescript,
        "css": .css, "scss": .css,
        "php": .php,
    ]

    /// Language names after the opening ``` of a Markdown code block.
    private static let fenceTags: [String: FileType] = [
        "python": .python, "py": .python, "python3": .python,
        "swift": .swift,
        "c": .cpp, "h": .cpp, "cpp": .cpp, "c++": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp,
        "cs": .csharp, "csharp": .csharp, "c#": .csharp,
        "js": .javascript, "javascript": .javascript, "jsx": .javascript, "mjs": .javascript, "node": .javascript,
        "ts": .typescript, "typescript": .typescript, "tsx": .typescript,
        "css": .css, "scss": .css,
        "php": .php,
        "json": .json, "yaml": .yaml, "yml": .yaml, "xml": .xml, "html": .html, "htm": .html,
        "ini": .config, "toml": .config, "tex": .tex, "latex": .tex, "log": .log,
    ]

    static func fromFenceTag(_ tag: String) -> FileType? {
        fenceTags[tag.split(whereSeparator: { $0.isWhitespace || $0 == "{" }).first.map { $0.lowercased() } ?? ""]
    }

    /// Starter content for a newly created file.
    static func template(forExtension ext: String) -> String {
        switch ext {
        case "md", "markdown", "mdown": return "# \n\n"
        case "json": return "{\n  \n}\n"
        case "csv": return "column1,column2\n"
        case "tsv": return "column1\tcolumn2\n"
        case "html", "htm": return "<!DOCTYPE html>\n<html>\n<head>\n  <meta charset=\"utf-8\">\n  <title></title>\n</head>\n<body>\n\n</body>\n</html>\n"
        case "xml": return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        case "tex": return "\\documentclass{article}\n\\begin{document}\n\n\\end{document}\n"
        case "swift": return "import Foundation\n\n"
        case "c": return "#include <stdio.h>\n\nint main(void) {\n    return 0;\n}\n"
        case "cpp", "cc", "cxx": return "#include <iostream>\n\nint main() {\n    return 0;\n}\n"
        case "h", "hpp", "hh", "hxx": return "#pragma once\n"
        case "cs": return "using System;\n\nclass Program\n{\n    static void Main()\n    {\n    }\n}\n"
        case "js", "mjs", "cjs", "jsx": return "'use strict';\n\n"
        case "css", "scss": return "body {\n}\n"
        case "php": return "<?php\n\n"
        default: return ""
        }
    }

    static var allExtensions: [String] { Array(extensions.keys).sorted() }

    init(url: URL) {
        self = FileType.extensions[url.pathExtension.lowercased()] ?? .text
    }

    var title: String {
        switch self {
        case .markdown: return "Markdown"
        case .text: return "Text"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .csv: return "CSV"
        case .log: return "Log"
        case .xml: return "XML"
        case .html: return "HTML"
        case .config: return "INI / TOML"
        case .tex: return "TeX"
        case .rtf: return "RTF"
        case .python: return "Python"
        case .swift: return "Swift"
        case .cpp: return "C / C++"
        case .csharp: return "C#"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .css: return "CSS"
        case .php: return "PHP"
        }
    }

    var symbol: String {
        switch self {
        case .markdown, .rtf: return "doc.richtext"
        case .json: return "curlybraces"
        case .yaml, .config, .xml, .html, .tex: return "doc.text"
        case .csv: return "tablecells"
        case .log: return "list.bullet.rectangle"
        case .text: return "doc.plaintext"
        case .python, .swift, .cpp, .csharp, .javascript, .typescript, .css, .php:
            return "chevron.left.forwardslash.chevron.right"
        }
    }
}
