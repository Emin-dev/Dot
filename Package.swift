// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DotCore", platforms: [.macOS("15.0")], targets: [
    .target(name: "DotCore", path: "src", exclude: ["App.swift", "ChatView.swift", "Engine.swift", "Models.swift", "Speech.swift"], sources: ["InteractionCore.swift"]),
    .testTarget(name: "DotCoreTests", dependencies: ["DotCore"], path: "Tests/DotCoreTests")
])
