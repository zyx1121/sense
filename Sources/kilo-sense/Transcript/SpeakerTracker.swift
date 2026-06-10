import AVFoundation
import FluidAudio
import Foundation

/// 系統音訊的分人（誰在講）。LS-EEND streaming diarizer 吃跟 ASR 同一條 16k mono 流，
/// 產出「speaker × 時間段」；ASR final 拿 audioTimeRange 來查主講者，
/// 會議模式下把對方的不同說話者標成 對方 A / 對方 B…（全程 on-device）。
///
/// 時鐘對齊：ASR 的 audioTimeRange 從 app 啟動連續累計；diarizer 只在會議中被餵。
/// 每次恢復餵食時記 offset = 當下 ASR 流秒數 − diarizer 已餵秒數，
/// segment 換算回 ASR 時間軸後才發布 — 兩個時鐘在同一條 buffer 流上，session 內零漂移。
actor SpeakerDiarizerPump {
    private enum Feed {
        case audio(PCMBuffer, streamSeconds: Double)
        case gap   // 會議關閉 → 下次恢復重算 offset
    }

    private let timeline: SpeakerTimeline
    private let queue: AsyncStream<Feed>
    private let intake: AsyncStream<Feed>.Continuation
    private var diarizer: LSEENDDiarizer?
    private var fedSeconds: Double = 0
    private var offset: Double = 0
    private var idle = true
    private var segments: [SpeakerTimeline.Segment] = []

    init(timeline: SpeakerTimeline) {
        self.timeline = timeline
        (queue, intake) = AsyncStream.makeStream(of: Feed.self)
        Task { await self.run() }
    }

    /// 音訊主迴圈呼叫 — 零成本入列，不等推理（首次 model 下載要數秒，不能卡 ASR fan-out）。
    nonisolated func enqueue(_ buffer: PCMBuffer, streamSeconds: Double) {
        intake.yield(.audio(buffer, streamSeconds: streamSeconds))
    }

    /// 會議關閉：標記 gap。
    nonisolated func pause() {
        intake.yield(.gap)
    }

    private func run() async {
        for await item in queue {
            switch item {
            case .gap:
                idle = true
            case .audio(let buffer, let streamSeconds):
                await consume(buffer, streamSeconds: streamSeconds)
            }
        }
    }

    private func consume(_ buffer: PCMBuffer, streamSeconds: Double) async {
        do {
            if diarizer == nil {
                Telemetry.meeting.info("diarizer init…（首次需下載 model）")
                let d = LSEENDDiarizer()
                try await d.initialize(variant: .dihard3)
                diarizer = d
                Telemetry.meeting.info("diarizer ready")
            }
            guard let diarizer, let samples = Self.samples(buffer.pcm) else { return }
            if idle {
                offset = streamSeconds - fedSeconds
                idle = false
            }
            try diarizer.addAudio(samples, sourceSampleRate: 16_000)
            fedSeconds += Double(samples.count) / 16_000
            if let update = try diarizer.process() {
                ingest(update)
            }
        } catch {
            Telemetry.meeting.error("diarizer error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ingest(_ update: DiarizerTimelineUpdate) {
        func convert(_ s: DiarizerSegment) -> SpeakerTimeline.Segment {
            SpeakerTimeline.Segment(
                speaker: String(s.speakerIndex),
                start: offset + Double(s.startTime),
                end: offset + Double(s.endTime))
        }
        let new = update.finalizedSegments.map(convert)
        // 暫定段（近即時、會被修訂）每次整批換新 — ASR final 立即 kick 的長句靠它們
        // 才查得到講者；定稿段一到，下次 update 的暫定段自然不再涵蓋該區間。
        let tentative = update.tentativeSegments.map(convert)
        guard !new.isEmpty || !tentative.isEmpty else { return }
        for s in new {  // segment 級觀測：diarizer 到底分出幾個講者、時間段落在哪
            Telemetry.meeting.info("segment spk=\(s.speaker, privacy: .public) \(s.start, format: .fixed(precision: 1), privacy: .public)s–\(s.end, format: .fixed(precision: 1), privacy: .public)s")
        }
        segments.append(contentsOf: new)
        if segments.count > 600 { segments.removeFirst(segments.count - 600) }  // 留近段就夠查
        let snapshot = segments + tentative
        let timeline = timeline
        Task { @MainActor in timeline.update(snapshot) }
    }

    private static func samples(_ pcm: AVAudioPCMBuffer) -> [Float]? {
        guard let p = pcm.floatChannelData, pcm.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: p[0], count: Int(pcm.frameLength)))
    }
}

/// 分人時間軸的 MainActor 快照 — commit 路徑（同步）查主講者用。
@MainActor
final class SpeakerTimeline {
    struct Segment: Sendable {
        let speaker: String   // diarizer 的 speaker id（session 內穩定）
        let start: Double     // ASR 時間軸秒
        let end: Double
    }

    private var segments: [Segment] = []
    private var letters: [String: String] = [:]  // speaker id → A/B/C…（首次出現順序）

    func update(_ s: [Segment]) {
        segments = s
    }

    /// time range 內重疊最多的說話者 → 「對方 A / 講者 A」式標籤；沒蓋到 → nil（fallback 前景 app）。
    /// requireMultipleSpeakers：近 120s 要看得到 ≥2 個講者才標 — 單講者內容（獨白影片）
    /// 保留 app 標題那個更有資訊量的來源，標「講者 A」反而是降級。
    func dominantLabel(start: Double, end: Double, prefix: String,
                       requireMultipleSpeakers: Bool) -> String? {
        if requireMultipleSpeakers {
            let recent = Set(segments.filter { $0.end > end - 120 }.map(\.speaker))
            guard recent.count >= 2 else { return nil }
        }
        var overlap: [String: Double] = [:]
        for seg in segments where seg.end > start && seg.start < end {
            overlap[seg.speaker, default: 0] += min(seg.end, end) - max(seg.start, start)
        }
        guard let best = overlap.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        return "\(prefix) \(letter(for: best.key))"
    }

    private func letter(for speaker: String) -> String {
        if let l = letters[speaker] { return l }
        let l = String(UnicodeScalar(UInt8(65 + letters.count % 26)))  // A, B, C…
        letters[speaker] = l
        return l
    }
}
