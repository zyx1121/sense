// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kilo-sense",
    platforms: [.macOS("26.0")], // SpeechAnalyzer / SpeechTranscriber 需 macOS 26
    dependencies: [
        // 分人 diart 範式：performCompleteDiarization streaming（一個 manager 維持跨 chunk
        // 全域 speaker ID）+ 自己 frame-level 切段，與 ASR 解耦、非同步疊加。
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.3"))
    ],
    targets: [
        .executableTarget(
            name: "kilo-sense",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/kilo-sense")
    ]
)
