// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WatchAICore",
    platforms: [.macOS(.v13), .watchOS("11.0")],
    products: [.library(name: "WatchAICore", targets: ["WatchAICore"])],
    targets: [
        .target(name: "WatchAICore", path: "Sources/Core"),
        .target(name: "WatchAIAudio", dependencies: ["WatchAICore"], path: "Sources/Shared",
                exclude: ["RealtimeClient.swift", "Theme.swift", "SystemWebSocket.swift", "SettingsEditor.swift", "NetworkWebSocket.swift"], sources: ["OpusCodec.swift", "SettingsStore.swift"]),
        .testTarget(name: "WatchAIAudioTests", dependencies: ["WatchAIAudio", "WatchAICore"], path: "Tests/AudioTests", resources: [.copy("Fixtures")]),
        .testTarget(name: "WatchAICoreTests", dependencies: ["WatchAICore"], path: "Tests/CoreTests")
    ]
)
