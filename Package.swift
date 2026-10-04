// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Smolder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Smolder",
            path: "Sources/Smolder",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "SmolderTests",
            dependencies: ["Smolder"],
            path: "Tests/SmolderTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
