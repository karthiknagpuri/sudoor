// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sudoor",
    platforms: [.macOS(.v13)],
    targets: [
        // The Dynamic Island prompt at the notch (approve/deny helper).
        .executableTarget(name: "IslandPrompt", path: "Sources/IslandPrompt"),
        // The menu bar agent (alien icon, pending list, counter, login item).
        .executableTarget(name: "SudoorBar", path: "Sources/SudoorBar"),
    ]
)
