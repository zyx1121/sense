// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kilo-sense",
    platforms: [.macOS("26.0")], // SpeechAnalyzer / SpeechTranscriber 需 macOS 26
    dependencies: [
        // 分人（speaker diarization）：pyannote/WeSpeaker/LS-EEND 的 CoreML 移植
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0")
    ],
    targets: [
        .executableTarget(
            name: "kilo-sense",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/kilo-sense")
    ]
)
