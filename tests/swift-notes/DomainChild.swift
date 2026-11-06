import Foundation

/// Дочерние режимы, общие для тестов аварий и вертикального сценария.
func handleExtraChild() async -> Bool {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--vertical-child"), args.count > i + 1 {
        do { try await verticalChild(dir: URL(fileURLWithPath: args[i + 1])) }
        catch { print("child error \(error)"); _exit(6) }
    }
    return false
}
