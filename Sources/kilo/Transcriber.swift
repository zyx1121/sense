import AVFoundation
import Foundation
import Speech

enum TranscriberError: Error {
    case localeNotSupported(String)
    case noAudioFormat
}

/// SpeechAnalyzer + SpeechTranscriber 包裝：volatile 進 CaptionModel；
/// 每段 final 同時餵 onFinal（給 Summarizer）。串接參考 swift-scribe。
@MainActor
final class Transcriber {
    private let locale: Locale
    private let captions: CaptionModel
    private let onFinal: (@MainActor (String) -> Void)?
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private let inputSequence: AsyncStream<AnalyzerInput>
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private let converter = BufferConverter()

    init(locale: Locale, captions: CaptionModel, onFinal: (@MainActor (String) -> Void)? = nil) {
        self.locale = locale
        self.captions = captions
        self.onFinal = onFinal
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputSequence = stream
        self.inputBuilder = continuation
    }

    func setUp() async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],  // fastResults：偏即時
            attributeOptions: [.audioTimeRange])
        self.transcriber = transcriber
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        try await ensureModel(transcriber: transcriber, locale: locale)

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerFormat = format
        guard let format else { throw TranscriberError.noAudioFormat }
        try await analyzer.prepareToAnalyze(in: format)  // ANE 預熱

        let captions = self.captions
        let onFinal = self.onFinal
        resultsTask = Task {
            do {
                for try await case let result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        captions.commitFinal(text)
                        onFinal?(text)               // 餵 Summarizer（只送定稿）
                    } else {
                        captions.setVolatile(text)
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("results error: \(error)\n".utf8))
            }
        }

        try await analyzer.start(inputSequence: inputSequence)
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
