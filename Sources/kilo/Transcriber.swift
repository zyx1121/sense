import AVFoundation
import Foundation
import Speech

enum TranscriberError: Error {
    case localeNotSupported(String)
    case noAudioFormat
}

/// SpeechAnalyzer + SpeechTranscriber 的 CLI 包裝。
/// 串接參考 FluidInference/swift-scribe（iOS26/macOS26 實作）。
@MainActor
final class Transcriber {
    private let locale: Locale
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private let inputSequence: AsyncStream<AnalyzerInput>
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private let converter = BufferConverter()

    init(locale: Locale) {
        self.locale = locale
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputSequence = stream
        self.inputBuilder = continuation
    }

    func setUp() async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange])
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])

        try await ensureModel(transcriber: transcriber, locale: locale)

        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard analyzerFormat != nil else { throw TranscriberError.noAudioFormat }

        // 持續消費辨識結果：volatile 灰字單行覆蓋、final 白字定稿換行
        resultsTask = Task {
            do {
                for try await case let result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        Self.printFinal(text)
                    } else {
                        Self.printVolatile(text)
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("results error: \(error)\n".utf8))
            }
        }

        try await analyzer?.start(inputSequence: inputSequence)
    }

    func stream(_ buffer: PCMBuffer) async throws {
        guard let analyzerFormat else { throw TranscriberError.noAudioFormat }
        let converted = try converter.convertBuffer(buffer.pcm, to: analyzerFormat)
        inputBuilder.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async throws {
        inputBuilder.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
    }

    // ANSI：[2K 清行 + \r 回行首；volatile 灰(90m)、final 還原(0m)
    nonisolated private static func printVolatile(_ t: String) {
        print("\r\u{1B}[2K\u{1B}[90m\(t)\u{1B}[0m", terminator: "")
        fflush(stdout)
    }
    nonisolated private static func printFinal(_ t: String) {
        print("\r\u{1B}[2K\u{1B}[0m\(t)")
    }
}

extension Transcriber {
    /// 確認語言 model 可用：supported 檢查 → 需要就下載 → reserve 配額。
    func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
        guard await supported(locale) else {
            throw TranscriberError.localeNotSupported(locale.identifier)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            FileHandle.standardError.write(Data("下載 \(locale.identifier) 語音 model…\n".utf8))
            try await request.downloadAndInstall()
        }
        try await reserve(locale)
    }

    private func supported(_ locale: Locale) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    private func reserve(_ locale: Locale) async throws {
        let allocated = await AssetInventory.reservedLocales
        if allocated.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return }
        try await AssetInventory.reserve(locale: locale)
    }
}
