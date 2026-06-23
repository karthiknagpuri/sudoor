// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sudoor",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SudoorCore", path: "Sources/SudoorCore"),
        // The Dynamic Island prompt at the notch (approve/deny helper).
        .executableTarget(name: "IslandPrompt", dependencies: ["SudoorCore"], path: "Sources/IslandPrompt"),
        // The menu bar agent (alien icon, pending list, counter, login item).
        .executableTarget(name: "SudoorBar", dependencies: ["SudoorCore"], path: "Sources/SudoorBar"),
        .testTarget(name: "SudoorCoreTests", dependencies: ["SudoorCore"], path: "Tests/SudoorCoreTests"),
    ]
)
