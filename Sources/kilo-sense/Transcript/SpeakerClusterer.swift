import AVFoundation
import FluidAudio
import Foundation

/// 分人總開關 — `--diarize` 才啟用（預設關）。關閉時整條 clusterer 不建、FluidAudio
/// embedding 模型不下載、audio loop 不 feed，零額外成本。
let diarizationEnabled = CommandLine.arguments.contains("--diarize")

/// 系統音訊的「不同人講話」分離 —— 不跑 EEND streaming diarizer（那條會在換手點翻
/// 講者身分，已於 2026-06-14 移除）。改採 **per-segment embedding + 線上最近質心分群**：
///
/// 每段 ASR final 定稿時，從 16k ring 撈該段音訊 → 抽一個 WeSpeaker embedding（FluidAudio
/// 的 `extractSpeakerEmbedding`，純 embedding、不經 diarizer）→ 跟目前累積的匿名質心比
/// cosine distance：最近且 < 門檻 = 那個字母（質心併入更新），都不像 = 開新字母（A、B、C…）。
///
/// 為什麼這不是上次失敗那條：這是**逐段獨立查表**，沒有 EEND 跨 chunk 的 permutation 要維護，
/// 身分穩定來自「持久質心 registry」而非「模型每段重判」，所以不會 catastrophic A↔B 翻。
/// 已知弱點（誠實）：聲音很像的人會併成同一字母；太短的句子 embedding 不穩；overlap/搶話
/// 不處理；一個 ASR final 段內若兩人接連講會被當一人。門檻 `--diarize-threshold` 可調，
/// 所有距離進 log（category=meeting）供現場調參。
///
/// 時鐘對齊：ring 以 `streamSeconds`（audio loop 連續累計的 ASR 流秒數）索引，ASR final 的
/// audioTimeRange 同一條 buffer 流、同一時鐘 — 兩者直接對得上，session 內零漂移。
actor SpeakerClusterer {
    private enum Feed {
        case audio([Float], start: Double)
        case warmup
    }

    /// 線上最近質心分群的合併門檻（cosine distance，越小越像）。
    /// 0.5 = 介於 FluidAudio「高信心同人」(~0.45) 與「同流 assignment」(~0.65) 之間：
    /// 同 session 同收音條件下，真同人通常 ≲0.4、不同人 ≳0.6。`--diarize-threshold` 可覆蓋。
    private static let mergeDistance: Float = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--diarize-threshold"), a.indices.contains(i + 1),
           let v = Float(a[i + 1]) { return v }
        return 0.5
    }()

    /// 短於此秒數的段不判（embedding 不穩，徒增亂跳）。
    private static let minSeconds = 1.2

    private let timeline: SpeakerTimeline
    private let queue: AsyncStream<Feed>
    private let intake: AsyncStream<Feed>.Continuation

    private var manager: DiarizerManager?     // 只用 extractSpeakerEmbedding，不跑 diarizer
    private var managerFailed = false
    private var ring: [(samples: [Float], start: Double)] = []
    private var ringSamples = 0               // running total，免每顆 buffer O(n) reduce

    /// 匿名講者質心 registry — index 0 = A、1 = B…。acc = 該講者所有 embedding 的和
    /// （比對前 normalize），count = 段數。session 內持久、跨 session 不留（匿名不做命名/聲紋）。
    private struct Cluster { let letter: String; var acc: [Float]; var count: Int }
    private var clusters: [Cluster] = []

    init(timeline: SpeakerTimeline) {
        self.timeline = timeline
        (queue, intake) = AsyncStream.makeStream(of: Feed.self)
        Task { await self.run() }
    }

    /// audio loop 呼叫 — 零成本入列（nonisolated yield，不卡 ASR fan-out）。
    nonisolated func feed(_ buffer: PCMBuffer, at start: Double) {
        guard let s = Self.samples(buffer.pcm) else { return }
        intake.yield(.audio(s, start: start))
    }

    /// 開機預熱 embedding 模型（首次需下載 ~100MB CoreML），免跟第一句語音賽跑。
    nonisolated func warmUp() { intake.yield(.warmup) }

    private func run() async {
        for await item in queue {
            switch item {
            case .warmup:
                await ensureManager()
            case .audio(let samples, let start):
                ring.append((samples, start))
                ringSamples += samples.count
                while ringSamples > 60 * 16_000, let first = ring.first {  // 留近 60s 夠 commit 時回撈
                    ringSamples -= first.samples.count
                    ring.removeFirst()
                }
            }
        }
    }

    /// init embedding 模型（含首次下載）。冪等；失敗後不再重試（fallback：不分人）。
    private func ensureManager() async {
        guard manager == nil, !managerFailed else { return }
        do {
            Telemetry.meeting.info("speaker embedding model init…（首次需下載 model）")
            let models = try await DiarizerModels.downloadIfNeeded()
            let m = DiarizerManager()
            m.initialize(models: models)
            manager = m
            Telemetry.meeting.info("speaker embedding model ready")
        } catch {
            managerFailed = true
            Telemetry.meeting.error("speaker embedding model unavailable — 分人停用：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 某段 ASR final 定稿 → 抽 embedding、配字母、發布到 timeline（commit 路徑查得到）。
    /// 回傳配到的字母（nil = 太短 / 模型沒就緒 / 音訊撈不到）。
    @discardableResult
    func label(start: Double, end: Double) async -> String? {
        guard end - start >= Self.minSeconds else { return nil }
        await ensureManager()
        guard let manager else { return nil }
        let audio = audioSlice(start: start, end: end)
        guard audio.count >= Int(Self.minSeconds * 16_000) else { return nil }
        do {
            let emb = try manager.extractSpeakerEmbedding(from: audio)
            let letter = assign(emb)
            let timeline = timeline
            await MainActor.run { timeline.add(start: start, end: end, letter: letter) }
            return letter
        } catch {
            Telemetry.meeting.error("embedding extract failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// embedding → 最近質心字母（或開新字母）。距離進 log 供調門檻。
    private func assign(_ emb: [Float]) -> String {
        var bestIdx = -1
        var bestDist = Float.greatestFiniteMagnitude
        for (i, c) in clusters.enumerated() {
            let d = SpeakerUtilities.cosineDistance(emb, Self.normalized(c.acc))
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        if bestIdx >= 0, bestDist < Self.mergeDistance {
            clusters[bestIdx].acc = zip(clusters[bestIdx].acc, emb).map(+)
            clusters[bestIdx].count += 1
            Telemetry.meeting.info("speaker \(self.clusters[bestIdx].letter, privacy: .public)（dist=\(bestDist, format: .fixed(precision: 2), privacy: .public)，已 \(self.clusters[bestIdx].count, privacy: .public) 段）")
            return clusters[bestIdx].letter
        }
        let letter = String(UnicodeScalar(UInt8(65 + clusters.count % 26)))  // A、B、C…
        clusters.append(Cluster(letter: letter, acc: emb, count: 1))
        Telemetry.meeting.info("speaker new \(letter, privacy: .public)（最近 dist=\(bestDist == .greatestFiniteMagnitude ? -1 : bestDist, format: .fixed(precision: 2), privacy: .public)，共 \(self.clusters.count, privacy: .public) 人）")
        return letter
    }

    /// 從 ring 撈 [start, end]（stream 時鐘）對應的音訊樣本。
    private func audioSlice(start: Double, end: Double) -> [Float] {
        var out: [Float] = []
        for chunk in ring {
            let chunkEnd = chunk.start + Double(chunk.samples.count) / 16_000
            let s = max(start, chunk.start), e = min(end, chunkEnd)
            guard e > s else { continue }
            let from = Int((s - chunk.start) * 16_000), to = Int((e - chunk.start) * 16_000)
            out.append(contentsOf: chunk.samples[max(0, from)..<min(chunk.samples.count, to)])
        }
        return out
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    private static func samples(_ pcm: AVAudioPCMBuffer) -> [Float]? {
        guard let p = pcm.floatChannelData, pcm.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: p[0], count: Int(pcm.frameLength)))
    }
}

// MARK: - 分人 self-test（headless，不需 TCC / 音訊擷取）

/// `--diarize-selftest <audio…>`：對一組音檔各抽一個 embedding，印 cosine 距離矩陣。
/// 驗核心假設「同人 < 門檻 < 不同人」、調 `--diarize-threshold` 用。中括號標 < mergeDistance 的格。
func runDiarizeSelfTest() async {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--diarize-selftest") else { return }
    let paths = args[(i + 1)...].prefix { !$0.hasPrefix("--") }
    guard paths.count >= 2 else { print("用法：--diarize-selftest <a.wav> <b.wav> …（≥2 檔）"); return }

    let threshold = Float(args.firstIndex(of: "--diarize-threshold").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "") ?? 0.5
    print("→ 下載 / 載入 speaker embedding model…")
    guard let models = try? await DiarizerModels.downloadIfNeeded() else { print("✗ model 載入失敗"); return }
    let m = DiarizerManager(); m.initialize(models: models)

    var embs: [(name: String, emb: [Float])] = []
    for p in paths {
        guard let s = loadAudio16kMono(p) else { print("✗ 讀檔失敗 \(p)"); continue }
        guard let e = try? m.extractSpeakerEmbedding(from: s) else { print("✗ 抽 embedding 失敗 \(p)"); continue }
        embs.append((((p as NSString).lastPathComponent), e))
        print(String(format: "  載入 %@ — %.1fs", (p as NSString).lastPathComponent, Double(s.count) / 16_000))
    }
    guard embs.count >= 2 else { return }

    print("\n=== cosine distance matrix（門檻 \(threshold)，[…] = 判同人）===")
    let head = embs.map { String($0.name.prefix(10)).padding(toLength: 10, withPad: " ", startingAt: 0) }.joined(separator: " ")
    print(String(repeating: " ", count: 11) + head)
    for (an, a) in embs {
        var row = String(an.prefix(10)).padding(toLength: 10, withPad: " ", startingAt: 0) + " "
        for (_, b) in embs {
            let d = SpeakerUtilities.cosineDistance(a, b)
            let cell = String(format: "%.3f", d)
            row += (d < threshold ? "[\(cell)]  " : " \(cell)   ")
        }
        print(row)
    }
    print("\n判讀：同一人不同片段的格應 < 門檻（落 [] 內）、不同人應 > 門檻。若不同人也落 [] → 調低門檻。")
}

/// 任意音檔 → 16k mono Float32（self-test 用；一次性整檔轉換，僅適合短片段）。
private func loadAudio16kMono(_ path: String) -> [Float]? {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
          let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
          let conv = AVAudioConverter(from: file.processingFormat, to: out),
          let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: inBuf)) != nil else { return nil }
    let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16_000 / file.processingFormat.sampleRate + 4096)
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { return nil }
    var fed = false
    var err: NSError?
    conv.convert(to: outBuf, error: &err) { _, status in
        if fed { status.pointee = .noDataNow; return nil }
        fed = true; status.pointee = .haveData; return inBuf
    }
    guard err == nil, let p = outBuf.floatChannelData else { return nil }
    return Array(UnsafeBufferPointer(start: p[0], count: Int(outBuf.frameLength)))
}

/// 分人時間軸的 MainActor 快照 — commit 路徑（同步）查某段的主講者字母用。
/// clusterer 在背景 actor 抽完 embedding 後發布 (start, end, letter)，commit 時 ASR
/// 已落後 ~1s，字母早已就緒。
@MainActor
final class SpeakerTimeline {
    private struct Seg { let start: Double; let end: Double; let letter: String }
    private var segs: [Seg] = []

    func add(start: Double, end: Double, letter: String) {
        segs.append(Seg(start: start, end: end, letter: letter))
        if segs.count > 800 { segs.removeFirst(segs.count - 800) }  // 留近段就夠查
    }

    /// time range 內重疊最多的字母。
    func dominantLetter(start: Double, end: Double) -> String? {
        var overlap: [String: Double] = [:]
        for s in segs where s.end > start && s.start < end {
            overlap[s.letter, default: 0] += min(s.end, end) - max(s.start, start)
        }
        return overlap.max(by: { $0.value < $1.value })?.key
    }

    func reset() { segs = [] }
}
