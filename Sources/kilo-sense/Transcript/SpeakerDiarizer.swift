import AVFoundation
import FluidAudio
import Foundation

/// 分人總開關 — `--diarize` 才啟用（預設關）。關閉時 diarizer 不建、模型不下載、
/// audio loop 不 feed，零額外成本。
let diarizationEnabled = CommandLine.arguments.contains("--diarize")

/// `--diarize-debug`：每個 diarizer segment 的 speakerId / 時間 / 字母進 log，調門檻用。
let diarizeDebug = CommandLine.arguments.contains("--diarize-debug")

/// 系統音訊的分人 —— diart 範式：與 ASR **解耦**的獨立軌，跑在原始音訊上、自己做
/// frame-level segmentation，講者標**非同步**疊回逐字稿。
///
/// 為什麼這條跟之前兩次都不一樣：
/// - ❌ #100 在 ASR final（8–32s 大塊、一塊含多人）上抽單一 embedding = 平均人聲拆不開。
///   這裡反過來：FluidAudio diarizer 自己在原始音訊上切細段，**邊界由 diarizer 決定，不是 ASR chunk**。
/// - ❌ #77 streaming EEND 當下即時 commit，換手點翻身分不可回改。這裡標籤晚 ~chunk 秒、
///   用一個常駐 `DiarizerManager` 維持**跨 chunk 全域穩定的 speakerId**（內建增量分群），
///   再以時間戳對齊（WhisperX 式）疊回已顯示的逐字稿（`TranscriptStore.refreshSpeakers`）。
///
/// 仍逃不掉的天花板（誠實）：相似同語言人聲 embedding 重疊、overlap/搶話 — 那是模型極限，非架構問題。
///
/// 時鐘：chunk 以 `atTime`（audio loop 連續累計的 ASR 流秒數）餵入，segment 回傳絕對時間，
/// 與 ASR 的 `audioTimeRange` 同一條 buffer 流、同時鐘（已證 slice==range），直接對得上。
actor SpeakerDiarizer {
    private enum Feed { case audio([Float], start: Double); case warmup }

    /// pyannote clustering 門檻（0.5–0.9，低=更多講者）。FluidAudio 預設 0.7；`--diarize-threshold` 可覆蓋。
    private static let clusteringThreshold: Float = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--diarize-threshold"), a.indices.contains(i + 1),
           let v = Float(a[i + 1]) { return v }
        return 0.7
    }()

    /// 累積到這麼多秒就餵一個 chunk 給 diarizer（= 講者標的非同步延遲；越大段切越穩、延遲越高）。
    private static let chunkSeconds = 10.0

    private let timeline: SpeakerTimeline
    private let onUpdate: @MainActor @Sendable () -> Void
    private let queue: AsyncStream<Feed>
    private let intake: AsyncStream<Feed>.Continuation

    private var manager: DiarizerManager?
    private var managerFailed = false
    private var pending: [Float] = []
    private var pendingStart: Double = 0   // pending buffer 第一顆 sample 的流秒數
    private var haveStart = false
    private var letters: [String: String] = [:]   // diarizer speakerId → A/B/C（首見順序，全域穩定）

    init(timeline: SpeakerTimeline, onUpdate: @escaping @MainActor @Sendable () -> Void) {
        self.timeline = timeline
        self.onUpdate = onUpdate
        (queue, intake) = AsyncStream.makeStream(of: Feed.self)
        Task { await self.run() }
    }

    /// audio loop 呼叫 — 零成本入列（nonisolated yield，不卡 ASR fan-out）。
    nonisolated func feed(_ buffer: PCMBuffer, at start: Double) {
        guard let s = Self.samples(buffer.pcm) else { return }
        intake.yield(.audio(s, start: start))
    }

    /// 開機預熱（首次需下載 pyannote CoreML 模型）。
    nonisolated func warmUp() { intake.yield(.warmup) }

    private func run() async {
        for await item in queue {
            switch item {
            case .warmup:
                await ensureModels()
            case .audio(let s, let start):
                if !haveStart { pendingStart = start; haveStart = true }
                pending.append(contentsOf: s)
                if Double(pending.count) >= Self.chunkSeconds * 16_000 { await flush() }
            }
        }
    }

    /// init pyannote segmentation + embedding 模型（含首次下載）。冪等；失敗不再重試。
    private func ensureModels() async {
        guard manager == nil, !managerFailed else { return }
        do {
            Telemetry.meeting.info("diarizer model init…（首次需下載 pyannote CoreML）")
            let models = try await DiarizerModels.downloadIfNeeded()
            var cfg = DiarizerConfig.default
            cfg.clusteringThreshold = Self.clusteringThreshold
            let m = DiarizerManager(config: cfg)
            m.initialize(models: models)
            manager = m
            Telemetry.meeting.info("diarizer ready（threshold \(Self.clusteringThreshold, privacy: .public)）")
        } catch {
            managerFailed = true
            Telemetry.meeting.error("diarizer unavailable — 分人停用：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 餵一個 chunk 給 diarizer → 拿全域穩定 speakerId 的 segments → 映射字母 → 發布到 timeline。
    private func flush() async {
        await ensureModels()
        let chunk = pending
        let start = pendingStart
        pending = []
        haveStart = false
        guard let manager, chunk.count >= Int(16_000) else { return }   // <1s 不值得跑
        do {
            let result = try manager.performCompleteDiarization(chunk, sampleRate: 16_000, atTime: start)
            let segs: [SpeakerTimeline.Seg] = result.segments.map { seg in
                let letter = letterFor(seg.speakerId)
                if diarizeDebug {
                    Telemetry.meeting.info("seg spk=\(seg.speakerId, privacy: .public)→\(letter, privacy: .public) \(seg.startTimeSeconds, format: .fixed(precision: 1), privacy: .public)–\(seg.endTimeSeconds, format: .fixed(precision: 1), privacy: .public)s q=\(seg.qualityScore, format: .fixed(precision: 2), privacy: .public)")
                }
                return SpeakerTimeline.Seg(start: Double(seg.startTimeSeconds),
                                           end: Double(seg.endTimeSeconds), letter: letter)
            }
            guard !segs.isEmpty else { return }
            let timeline = timeline
            let onUpdate = onUpdate
            await MainActor.run { timeline.add(segs); onUpdate() }   // 非同步疊回逐字稿
        } catch {
            Telemetry.meeting.error("diarize failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func letterFor(_ id: String) -> String {
        if let l = letters[id] { return l }
        let l = String(UnicodeScalar(UInt8(65 + letters.count % 26)))   // A、B、C…
        letters[id] = l
        return l
    }

    private static func samples(_ pcm: AVAudioPCMBuffer) -> [Float]? {
        guard let p = pcm.floatChannelData, pcm.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: p[0], count: Int(pcm.frameLength)))
    }
}

// MARK: - 分人 self-test（headless，不需 TCC / 音訊擷取）

/// `--diarize-selftest <audio…>`：把多個音檔**串成一段對話**餵 performCompleteDiarization，
/// 印 diarizer 自己切出的 segments（speakerId / 時間）+ 對照每檔的真實邊界（檔名首字母=講者）。
/// 驗 FluidAudio 的 segmentation + 全域分群在這批聲音上對不對。
func runDiarizeSelfTest() async {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--diarize-selftest") else { return }
    let paths = Array(args[(i + 1)...].prefix { !$0.hasPrefix("--") })
    guard !paths.isEmpty else { print("用法：--diarize-selftest <a.wav> <b.wav> …"); return }
    let threshold = Float(args.firstIndex(of: "--diarize-threshold").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "") ?? 0.7

    print("→ 載入 diarizer model（pyannote CoreML）…")
    guard let models = try? await DiarizerModels.downloadIfNeeded() else { print("✗ model 載入失敗"); return }
    var cfg = DiarizerConfig.default
    cfg.clusteringThreshold = threshold
    let m = DiarizerManager(config: cfg)
    m.initialize(models: models)

    // 串成一段「對話」+ 記錄每檔真實邊界（檔名如 d1/d2=講者 d、s1/s2=講者 s）。
    var combined: [Float] = []
    var truth: [(label: String, start: Double, end: Double)] = []
    for p in paths {
        guard let s = loadAudio16kMono(p) else { print("✗ 讀檔失敗 \(p)"); continue }
        let start = Double(combined.count) / 16_000
        combined.append(contentsOf: s)
        let end = Double(combined.count) / 16_000
        let name = (p as NSString).lastPathComponent
        truth.append((String(name.prefix(1)), start, end))
    }
    guard !combined.isEmpty else { return }

    print("\n=== 真實邊界（檔名首字母 = 講者）===")
    for t in truth { print(String(format: "  %@  %.1f–%.1fs", t.label, t.start, t.end)) }

    do {
        let result = try m.performCompleteDiarization(combined, sampleRate: 16_000)
        print("\n=== diarizer 切出的 segments（門檻 \(threshold)）===")
        var ids = Set<String>()
        for seg in result.segments {
            ids.insert(seg.speakerId)
            // 落在哪個真實區間
            let mid = Double(seg.startTimeSeconds + seg.endTimeSeconds) / 2
            let who = truth.first { mid >= $0.start && mid < $0.end }?.label ?? "?"
            print(String(format: "  spk=%@  %.1f–%.1fs  (真實=%@)", seg.speakerId, seg.startTimeSeconds, seg.endTimeSeconds, who))
        }
        print("\n判讀：diarizer 應切出 \(Set(truth.map(\.label)).count) 個講者；同一真實講者的段該拿到同一 spk id。實得 \(ids.count) 個 spk。")
    } catch {
        print("✗ diarize 失敗：\(error)")
    }
}

/// 任意音檔 → 16k mono Float32（self-test 用；一次性整檔轉換）。
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

/// 分人時間軸的 MainActor 快照 — diarizer 軌（落後 ASR ~chunk 秒）發布講者段，
/// commit / refresh 路徑用時間戳交集查某段主講者字母。
@MainActor
final class SpeakerTimeline {
    struct Seg: Sendable { let start: Double; let end: Double; let letter: String }
    private var segs: [Seg] = []

    func add(_ new: [Seg]) {
        segs.append(contentsOf: new)
        if segs.count > 4000 { segs.removeFirst(segs.count - 4000) }
    }

    /// time range 內重疊最多的字母（WhisperX 式時間戳交集）。
    func dominantLetter(start: Double, end: Double) -> String? {
        var overlap: [String: Double] = [:]
        for s in segs where s.end > start && s.start < end {
            overlap[s.letter, default: 0] += min(s.end, end) - max(s.start, start)
        }
        return overlap.max(by: { $0.value < $1.value })?.key
    }

    func reset() { segs = [] }
}
