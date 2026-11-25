// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipHistory",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ClipHistoryCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ClipHistory",
            dependencies: ["ClipHistoryCore"]
        ),
        .testTarget(
            name: "ClipHistoryCoreTests",
            dependencies: ["ClipHistoryCore"]
        ),
    ]
)
