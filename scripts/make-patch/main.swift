import Foundation

// Usage: make-patch <old Grizzly.app> <new Grizzly.app> <output.zip>
let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: make-patch <old Grizzly.app> <new Grizzly.app> <output.zip>\n".utf8))
    exit(2)
}
do {
    try AppPatch.build(oldApp: URL(fileURLWithPath: args[1]), newApp: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]))
} catch {
    FileHandle.standardError.write(Data("make-patch failed: \(error)\n".utf8))
    exit(1)
}
