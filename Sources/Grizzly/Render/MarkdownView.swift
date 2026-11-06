import SwiftUI

func inlineMarkdown(_ s: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
}
