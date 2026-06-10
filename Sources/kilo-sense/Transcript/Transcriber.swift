import AVFoundation
import Foundation
import Speech

enum TranscriberError: Error {
    case localeNotSupported(String)
    case noAudioFormat
}

/// 一路 ASR 的單筆結果：哪個語言、是否定稿、run 平均信心、音訊時間範圍。
struct ASRResult {
    let locale: String        // bcp47，如 "zh-TW"
    let text: String
    let isFinal: Bool
    let confidence: Double?   // .transcriptionConfidence run 平均；沒有就 nil
    let timeRange: CMTimeRange?  // 相對 analyzer 輸入流起點 — 分人對時用
}

/// SpeechAnalyzer + SpeechTranscriber 包裝：單一 locale 一路，結果統一走 onResult。
/// 中英雙路並跑時各自一個 instance，由 LanguageRouter 擇優。串接參考 swift-scribe。
@MainActor
final class Transcriber {
    private let locale: Locale
    private let onResult: @MainActor (ASRResult) -> Void
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private let inputSequence: AsyncStream<AnalyzerInput>
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private let converter = BufferConverter()

    init(locale: Locale, onResult: @escaping @MainActor (ASRResult) -> Void) {
        self.locale = locale
        self.onResult = onResult
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputSequence = stream
        self.inputBuilder = continuation
    }

    func setUp() async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],  // fastResults：偏即時
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        self.transcriber = transcriber
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        try await ensureModel(transcriber: transcriber, locale: locale)

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerFormat = format
        guard let format else { throw TranscriberError.noAudioFormat }
        try await analyzer.prepareToAnalyze(in: format)  // ANE 預熱

        let localeID = locale.identifier(.bcp47)
        let onResult = self.onResult
        resultsTask = Task {
            do {
                for try await case let result in transcriber.results {
                    let text = String(result.text.characters)
                    onResult(ASRResult(
                        locale: localeID,
                        text: text,
                        isFinal: result.isFinal,
                        confidence: Self.meanConfidence(result.text),
                        timeRange: Self.timeRange(result.text)))
                }
            } catch {
                FileHandle.standardError.write(Data("results error [\(localeID)]: \(error)\n".utf8))
            }
        }

        try await analyzer.start(inputSequence: inputSequence)
    }

    /// 整筆結果的音訊時間範圍（首 run 起點 → 末 run 終點；可能整串沒有 → nil）。
    private static func timeRange(_ text: AttributedString) -> CMTimeRange? {
        let ranges = text.runs.compactMap(\.audioTimeRange)
        guard let first = ranges.first, let last = ranges.last else { return nil }
        return CMTimeRange(start: first.start, end: last.end)
    }

    /// run 平均信心（以字元數加權；volatile 可能整串沒有 → nil）。
    private static func meanConfidence(_ text: AttributedString) -> Double? {
        var sum = 0.0
        var weight = 0
        for run in text.runs {
            guard let c = run.transcriptionConfidence else { continue }
            let n = text[run.range].characters.count
            sum += c * Double(n)
            weight += n
        }
        return weight > 0 ? sum / Double(weight) : nil
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
