// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DotCore", platforms: [.macOS("15.0")], targets: [
    .target(name: "DotCore", path: "src", exclude: ["App.swift", "CompanionPanel.swift", "ChatView.swift", "Engine.swift", "Models.swift", "Speech.swift", "BionicVoice.swift", "VoicePipeWriter.swift", "VoiceAudioReader.swift", "WhisperRecognizer.swift", "OfflinePayload.swift", "OfflinePreparation.swift", "BundledSplash.swift", "ScreenContext.swift"], sources: ["InteractionCore.swift", "RoamingCore.swift"]),
    .testTarget(name: "DotCoreTests", dependencies: ["DotCore"], path: "Tests/DotCoreTests")
])
