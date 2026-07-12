// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sense",
    platforms: [.macOS("26.0")], // SpeechAnalyzer / SpeechTranscriber 需 macOS 26
    targets: [
        .executableTarget(
            name: "sense",
            path: "Sources/sense")
    ]
)
