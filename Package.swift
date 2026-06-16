// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kilo-sense",
    platforms: [.macOS("26.0")], // SpeechAnalyzer / SpeechTranscriber 需 macOS 26
    dependencies: [
        // 分人：只用 WeSpeaker speaker embedding（extractSpeakerEmbedding）做線上質心分群，
        // 不跑 EEND streaming diarizer。pin 0.15.x — 鎖住已驗證的 embedding API surface。
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.0"))
    ],
    targets: [
        .executableTarget(
            name: "kilo-sense",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/kilo-sense")
    ]
)
