// swift-tools-version:5.9
import PackageDescription

// tools-version 5.9 ⇒ Ziel wird im Swift-5-Sprachmodus kompiliert.
// Dadurch greift die Swift-6-Strict-Concurrency nicht auf den AppKit-Code,
// eine explizite swiftLanguageMode-Angabe (erst ab PackageDescription 6.0
// verfügbar) ist hier nicht nötig.
let package = Package(
    name: "Espresso",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Espresso",
            path: "Sources/Espresso"
        )
    ]
)
