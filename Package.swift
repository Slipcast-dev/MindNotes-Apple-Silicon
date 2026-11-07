// swift-tools-version:6.2
import PackageDescription

// Приложение собирает scripts/build-app.sh, тесты запускает scripts/test.sh.
// Манифест нужен редакторам. Цель та же: только Apple Silicon, см. scripts/target.sh.
let package = Package(
    name: "MinervaNoema",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "MinervaNoema",
            path: "Sources/MinervaNoema",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
