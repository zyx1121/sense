// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kilo-sense",
    platforms: [.macOS("26.0")], // SpeechAnalyzer / SpeechTranscriber 需 macOS 26
    targets: [
        .executableTarget(
            name: "kilo-sense",
            path: "Sources/kilo-sense")
    ]
)
