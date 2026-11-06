import Foundation

/// Looks up a UI string for places SwiftUI does not localize by itself (plain `String` values).
/// Keys are the Russian source strings; `resources/en.lproj` holds the English translations.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}
