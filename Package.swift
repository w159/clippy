// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Clippy",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.3"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "Clippy",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Pure, dependency-free CLI logic (argument parser, sensitive-flag reader) so
        // tests can import it without building the CLI executable.
        .target(
            name: "ClippyCLICore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Command line tool. Named `clippy-cli` because the `Clippy` app executable would
        // collide with `clippy` in .build/ on case-insensitive volumes; make-app.sh installs
        // it as Contents/Resources/bin/clippy.
        .executableTarget(
            name: "clippy-cli",
            dependencies: [
                "ClippyCLICore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/ClippyCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClippyTests",
            dependencies: [
                "Clippy",
                "ClippyCLICore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
