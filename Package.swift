// swift-tools-version:6.2
import PackageDescription

// Приложение собирает scripts/build-app.sh, тесты запускает scripts/test.sh.
// Манифест нужен редакторам. Цель та же: только Apple Silicon, см. scripts/target.sh.
let package = Package(
    name: "MindNotes",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MindNotes",
            path: "Sources/MindNotes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
