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
        case enroll(name: String, ranges: [(start: Double, end: Double)])  // 命名 → 聲紋註冊
        case warmup  // 開機預熱：先 init + re-enroll,首句語音就認得人（不等 speech gate）
    }

    private let timeline: SpeakerTimeline
    private let queue: AsyncStream<Feed>
    private let intake: AsyncStream<Feed>.Continuation
    private var diarizer: LSEENDDiarizer?
    private var fedSeconds: Double = 0
    private var offset: Double = 0
    private var idle = true
    private var segments: [SpeakerTimeline.Segment] = []
    // 近 120s 原始音訊（stream 時間索引）— 聲紋註冊要回撈該講者的片段
    private var ring: [(samples: [Float], start: Double)] = []
    private var ringSamples = 0   // running total — 免每顆 buffer O(n) reduce
    private var enrolledNames: Set<String> = []
    private var lastPublish = Date.distantPast  // 純暫定段的發布節流

    // — 聲紋驗證閘：LS-EEND 沒有 open-set rejection，庫裡有人時陌生聲音會被硬配到
    // 最像的具名 slot（實測中文 podcast 被掛成英文節目 enroll 的 David/Sarah）。
    // 具名 slot 的 live 音訊累積 ≥3s 後抽 WeSpeaker embedding，跟 voices/ 原始樣本的
    // reference embedding 比 cosine distance：過門檻才放行名字，否則該 slot 本 session
    // 降級匿名（講者 X）。驗證器載不到 → fallback 直接信 LS-EEND（不啞掉）。
    // 已知限制：verdict 是 per-session per-slot 一次性 — 同 slot 先後host不同人不會重驗。
    private var verifier: DiarizerManager?
    private var verifierFailed = false
    private var referenceEmbeddings: [String: [Float]] = [:]
    private var slotVerdicts: [Int: Bool] = [:]   // slot → 驗證通過 / 拒絕
    private var slotPendingRanges: [Int: [(start: Double, end: Double)]] = [:]
    // 0.5 = 介於 FluidAudio「高信心同人」embeddingThreshold(0.45) 與同流 assignment(0.65)
    // 之間 — 開放集合跨情境驗證要比同流 assignment 嚴：實測 Meijia TTS 對 Samantha 聲紋
    // dist≈0.65，0.65 門檻會誤放行；真同人同條件通常 ≲0.4。
    private let verifyDistance: Float = 0.5
    private let verifyMinSeconds = 3.0

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

    /// LLM 推出名字 → 註冊聲紋（與音訊同佇列依序處理，diarizer 無並發競態）。
    nonisolated func requestEnroll(name: String, ranges: [(start: Double, end: Double)]) {
        intake.yield(.enroll(name: name, ranges: ranges))
    }

    /// 開機預熱（有聲紋庫才值得）— 不預熱的話 re-enroll 跟第一句語音賽跑，首句會 miss。
    nonisolated func warmUp() {
        intake.yield(.warmup)
    }

    private func run() async {
        for await item in queue {
            switch item {
            case .gap:
                idle = true
                // 恢復餵食時 offset 會重算 — 累積中的待驗證範圍跨時鐘不可信，
                // 重收（verdict 是 sticky 的，寧可慢不可髒）
                slotPendingRanges = [:]
            case .audio(let buffer, let streamSeconds):
                await consume(buffer, streamSeconds: streamSeconds)
            case .enroll(let name, let ranges):
                enroll(name: name, ranges: ranges)
            case .warmup:
                await ensureDiarizer()
            }
        }
    }

    /// init diarizer（含首次 model 下載）+ 把存檔聲紋 re-enroll 回去。冪等。
    private func ensureDiarizer() async {
        guard diarizer == nil else { return }
        do {
            Telemetry.meeting.info("diarizer init…（首次需下載 model）")
            let d = LSEENDDiarizer()
            try await d.initialize(variant: .dihard3)
            diarizer = d
            Telemetry.meeting.info("diarizer ready")
            reenrollSavedVoices(d)  // 聲紋註冊回去 — 跨 session 認人
            Task { await self.ensureVerifier() }  // 驗證器另載（下載 await 期間 actor 照常吃音訊）
        } catch {
            Telemetry.meeting.error("diarizer init failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 載 pyannote segmentation + WeSpeaker embedding（驗證用，跟 LS-EEND 分開），
    /// 並把 voices/ 的原始樣本各抽一條 reference embedding。失敗 → fallback 直接信 LS-EEND。
    private func ensureVerifier() async {
        guard verifier == nil, !verifierFailed else { return }
        let saved = VoiceStore.loadAll()
        guard !saved.isEmpty else { return }  // 沒聲紋庫就沒有 false-accept 問題
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let m = DiarizerManager()
            m.initialize(models: models)
            for (name, samples) in saved {
                referenceEmbeddings[name] = try m.extractSpeakerEmbedding(from: samples)
            }
            verifier = m
            Telemetry.enrich.info("voiceprint verifier ready（\(self.referenceEmbeddings.count, privacy: .public) refs）")
        } catch {
            verifierFailed = true
            Telemetry.enrich.error("voiceprint verifier unavailable — 直接信 LS-EEND：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func consume(_ buffer: PCMBuffer, streamSeconds: Double) async {
        await ensureDiarizer()
        do {
            guard let diarizer, let samples = Self.samples(buffer.pcm) else { return }
            if idle {
                offset = streamSeconds - fedSeconds
                idle = false
            }
            ring.append((samples, streamSeconds))
            ringSamples += samples.count
            while ringSamples > 120 * 16_000, let first = ring.first {
                ringSamples -= first.samples.count
                ring.removeFirst()
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

    // MARK: - 聲紋註冊（LLM 命名 → enroll → 跨 session 直接認人）

    /// 從 ring 撈該講者的片段音訊註冊聲紋。enroll 會 reset diarizer 內部 timeline
    ///（時鐘歸零）— 成功後重置 fedSeconds 並重算 offset，匿名字母/名字映射也清掉重排。
    /// 從 ring 撈指定時間範圍（stream 時鐘）的音訊 — 新範圍優先、總長封頂 capSeconds。
    private func collectAudio(ranges: [(start: Double, end: Double)], capSeconds: Double = 15) -> [Float] {
        var collected: [Float] = []
        for r in ranges.reversed() {
            for chunk in ring {
                let chunkEnd = chunk.start + Double(chunk.samples.count) / 16_000
                let s = max(r.start, chunk.start), e = min(r.end, chunkEnd)
                guard e > s else { continue }
                let from = Int((s - chunk.start) * 16_000), to = Int((e - chunk.start) * 16_000)
                collected.append(contentsOf: chunk.samples[max(0, from)..<min(chunk.samples.count, to)])
            }
            if collected.count >= Int(capSeconds * 16_000) { break }
        }
        return collected
    }

    private func enroll(name: String, ranges: [(start: Double, end: Double)]) {
        guard let diarizer, !enrolledNames.contains(name) else { return }
        let collected = collectAudio(ranges: ranges)
        guard collected.count >= 3 * 16_000 else {
            Telemetry.enrich.info("enroll skipped \(name, privacy: .public) — 聲音樣本不足 \(collected.count / 16_000, privacy: .public)s")
            return
        }
        do {
            guard let speaker = try diarizer.enrollSpeaker(withAudio: collected, sourceSampleRate: 16_000,
                                                           named: name) else {
                Telemetry.enrich.info("enroll rejected \(name, privacy: .public)")
                return
            }
            // 這個 slot 的身分是「從這段現場音訊」確認的 — 本 session 免再驗
            slotVerdicts[speaker.index] = true
            if let verifier { referenceEmbeddings[name] = try? verifier.extractSpeakerEmbedding(from: collected) }
            enrolledNames.insert(name)
            fedSeconds = 0; idle = true   // enroll reset 了 diarizer 時鐘 — 下顆 buffer 重算 offset
            VoiceStore.save(name: name, samples: collected)
            let timeline = timeline
            Task { @MainActor in timeline.resetAnonymous() }  // slot 重排，舊字母映射作廢
            Telemetry.enrich.info("enrolled \(name, privacy: .public)（\(collected.count / 16_000, privacy: .public)s 聲紋,已存 voices/）")
        } catch {
            Telemetry.enrich.error("enroll failed \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 開機 re-enroll：diarizer 不提供 embedding 匯出,聲紋以原始音訊形式持久化、每次啟動重註冊。
    private func reenrollSavedVoices(_ d: LSEENDDiarizer) {
        for (name, samples) in VoiceStore.loadAll() {
            do {
                if try d.enrollSpeaker(withAudio: samples, sourceSampleRate: 16_000, named: name) != nil {
                    enrolledNames.insert(name)
                    Telemetry.enrich.info("re-enrolled \(name, privacy: .public)")
                }
            } catch {
                Telemetry.enrich.error("re-enroll failed \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func ingest(_ update: DiarizerTimelineUpdate) {
        // 已 enroll 的講者 slot 帶名字（「David」），但要過聲紋驗證才放行 —
        // 未驗證 / 被拒的 slot 維持數字 → timeline 配字母（講者 X）。
        let names = diarizer?.timeline.speakers.compactMapValues(\.name) ?? [:]
        trackVerification(update, names: names)
        func convert(_ s: DiarizerSegment) -> SpeakerTimeline.Segment {
            let idx = s.speakerIndex
            let trusted = verifierFailed || slotVerdicts[idx] == true
            return SpeakerTimeline.Segment(
                speaker: trusted ? (names[idx] ?? String(idx)) : String(idx),
                start: offset + Double(s.startTime),
                end: offset + Double(s.endTime))
        }
        let new = update.finalizedSegments.map(convert)
        // 暫定段（近即時、會被修訂）每次整批換新 — ASR final 立即 kick 的長句靠它們
        // 才查得到講者；定稿段一到，下次 update 的暫定段自然不再涵蓋該區間。
        let tentative = update.tentativeSegments.map(convert)
        guard !new.isEmpty || !tentative.isEmpty else { return }
        // 發布節流：標籤解析在 polisher 取批時（秒級）才讀 — 純暫定更新沒必要 10Hz
        // 跨 actor 複製整條時間軸；有定稿段照樣立即發。
        if new.isEmpty, Date().timeIntervalSince(lastPublish) < 0.5 { return }
        lastPublish = Date()
        for s in new {  // segment 級觀測：diarizer 到底分出幾個講者、時間段落在哪
            Telemetry.meeting.info("segment spk=\(s.speaker, privacy: .public) \(s.start, format: .fixed(precision: 1), privacy: .public)s–\(s.end, format: .fixed(precision: 1), privacy: .public)s")
        }
        segments.append(contentsOf: new)
        if segments.count > 600 { segments.removeFirst(segments.count - 600) }  // 留近段就夠查
        let snapshot = segments + tentative
        let timeline = timeline
        Task { @MainActor in timeline.update(snapshot) }
    }

    /// 具名 slot 的驗證簿記：累積該 slot 的定稿段範圍，滿 3s 抽 embedding 對 reference 驗。
    private func trackVerification(_ update: DiarizerTimelineUpdate, names: [Int: String]) {
        guard !verifierFailed else { return }
        for s in update.finalizedSegments {
            let idx = s.speakerIndex
            guard names[idx] != nil, slotVerdicts[idx] == nil else { continue }
            slotPendingRanges[idx, default: []].append(
                (offset + Double(s.startTime), offset + Double(s.endTime)))
            if slotPendingRanges[idx]!.count > 20 { slotPendingRanges[idx]!.removeFirst() }
        }
        for (slot, ranges) in slotPendingRanges {
            guard slotVerdicts[slot] == nil, let name = names[slot] else { continue }
            let total = ranges.reduce(0) { $0 + ($1.end - $1.start) }
            guard total >= verifyMinSeconds else { continue }
            // verifier 還在載 / ring 已滾掉樣本 → 留著下次 update 再驗
            guard let verifier, let ref = referenceEmbeddings[name] else { continue }
            let audio = collectAudio(ranges: ranges)
            guard audio.count >= Int(verifyMinSeconds * 16_000) else { continue }
            do {
                let emb = try verifier.extractSpeakerEmbedding(from: audio)
                let dist = SpeakerUtilities.cosineDistance(emb, ref)
                let ok = dist < verifyDistance
                slotVerdicts[slot] = ok
                slotPendingRanges[slot] = nil
                Telemetry.enrich.info("voiceprint \(ok ? "verified" : "rejected", privacy: .public) slot \(slot, privacy: .public) → \(name, privacy: .public)（dist=\(dist, format: .fixed(precision: 2), privacy: .public)）")
            } catch {
                Telemetry.enrich.error("voiceprint verify failed slot \(slot, privacy: .public): \(error.localizedDescription, privacy: .public)")
                slotPendingRanges[slot] = nil  // 這批樣本壞了重收，不無限重試同批
            }
        }
    }

    private static func samples(_ pcm: AVAudioPCMBuffer) -> [Float]? {
        guard let p = pcm.floatChannelData, pcm.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: p[0], count: Int(pcm.frameLength)))
    }
}

/// 聲紋持久化：~/.kilo/voices/<name>.f32（16k mono Float32 raw）。
/// 存音訊不存 embedding — FluidAudio 不開放 embedding 匯出，且原始音訊跨 model 版本可重derive。
enum VoiceStore {
    static var dir: String { kiloWorkdir + "/voices" }

    static func save(name: String, samples: [Float]) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: URL(fileURLWithPath: "\(dir)/\(safe).f32"))
    }

    static func loadAll() -> [(name: String, samples: [Float])] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files.filter { $0.hasSuffix(".f32") }.compactMap { file in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(file)")) else { return nil }
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return (String(file.dropLast(4)), samples)
        }
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
    // 字母 → LLM 推出的顯示名（人名或「角色 字母」）— AttributionEnricher 每輪全量覆蓋，
    // 舊內容淡出後自然被新一輪結果清掉，不會把上個影片的名字套到下一個。
    private var displayNames: [String: String] = [:]

    func update(_ s: [Segment]) {
        segments = s
    }

    /// AttributionEnricher 寫入：全量覆蓋（沒提到的字母 = 清掉舊名）。
    func setDisplayNames(_ names: [String: String]) {
        displayNames = names
    }

    /// 任意講者標籤還原成字母 —「講者 B / 對方 B」→ B；已命名（「小明」）反查 displayNames。
    func canonicalLetter(for label: String?) -> String? {
        guard let label else { return nil }
        if let m = label.wholeMatch(of: /(?:講者|對方) ([A-Z])/) { return String(m.1) }
        return displayNames.first(where: { $0.value == label })?.key
    }

    /// time range 內重疊最多的說話者 → 標籤。已 enroll 的講者（speaker 鍵是名字而非數字）
    /// 直接回名字、不受 ≥2 講者規則限制 — 認得出身分就值得標，獨白也標。
    /// 匿名講者：「對方 A / 講者 A」式；requireMultipleSpeakers 時近 120s 要 ≥2 個講者才標 —
    /// 單講者內容保留 app 標題那個更有資訊量的來源。
    func dominantLabel(start: Double, end: Double, prefix: String,
                       requireMultipleSpeakers: Bool) -> String? {
        var overlap: [String: Double] = [:]
        for seg in segments where seg.end > start && seg.start < end {
            overlap[seg.speaker, default: 0] += min(seg.end, end) - max(seg.start, start)
        }
        guard let best = overlap.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        if Int(best.key) == nil { return best.key }  // 具名聲紋：鍵即名字
        if requireMultipleSpeakers {
            let recent = Set(segments.filter { $0.end > end - 120 }.map(\.speaker))
            guard recent.count >= 2 else { return nil }
        }
        let l = letter(for: best.key)
        return displayNames[l] ?? "\(prefix) \(l)"
    }

    /// 匿名映射世代 — resetAnonymous 遞增。enricher 靠這個發現字母已重排：
    /// 跨世代的「講者 A」是不同人，舊提案與舊輪替史不能再餵一致性閘。
    private(set) var anonymousGeneration = 0

    /// enroll 後 diarizer slot 重排 — 匿名映射（字母 / LLM 名）全部作廢重排，
    /// 下一輪 enrich 會基於新 slot 重建。
    func resetAnonymous() {
        letters = [:]
        displayNames = [:]
        anonymousGeneration += 1
    }

    /// 該字母是否已有顯示名（enricher 穩態降速的判斷）。
    func hasDisplayName(forLetter l: String) -> Bool {
        displayNames[l] != nil
    }

    /// 某字母講者近期的時間片段（給聲紋註冊撈音訊）：新到舊、總長封頂 15s。
    func segmentRanges(forLetter letter: String) -> [(start: Double, end: Double)] {
        guard let speaker = letters.first(where: { $0.value == letter })?.key else { return [] }
        var total = 0.0
        var out: [(Double, Double)] = []
        for seg in segments.filter({ $0.speaker == speaker }).sorted(by: { $0.end > $1.end }) {
            out.append((seg.start, seg.end))
            total += seg.end - seg.start
            if total >= 15 { break }
        }
        return out
    }

    private func letter(for speaker: String) -> String {
        if let l = letters[speaker] { return l }
        let l = String(UnicodeScalar(UInt8(65 + letters.count % 26)))  // A, B, C…
        letters[speaker] = l
        return l
    }
}
