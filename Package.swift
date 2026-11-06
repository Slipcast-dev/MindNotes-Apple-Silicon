// swift-tools-version:5.8
import PackageDescription

// The shipped app is built by scripts/build-app.sh (swiftc), which also builds the QuickLook extension.
// This manifest only serves editors and `swift build` with a full Xcode; tests run via scripts/test.sh.
let package = Package(
    name: "Grizzly",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Grizzly",
            path: "Sources/Grizzly"
        )
    ]
)
