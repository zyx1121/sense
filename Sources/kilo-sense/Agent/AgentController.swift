import AppKit
import CoreMedia
import Foundation
import UniformTypeIdentifiers

/// 圈選素材的快捷動作（chip 右鍵選單）。
enum QuickAction {
    case translate, explain, transcribe

    var label: String {
        switch self {
        case .translate: return "翻譯"
        case .explain: return "解釋"
        case .transcribe: return "抄錄文字"
        }
    }

    var instruction: String {
        switch self {
        case .translate: return "翻譯這個圈選內容：中文翻成英文、其他語言翻成繁體中文。只給譯文。"
        case .explain: return "解釋這個圈選內容：它是什麼、重點是什麼。繁體中文，簡潔。"
        case .transcribe: return "把圖中的文字完整抄錄出來，保持原語言與排版。"
        }
    }
}

/// overlay input → codex agent。逐字稿存在 TranscriptStore（也是 codex 的 context）。
/// 對話 history：記住 codex 的 thread id，每輪 `exec resume` 續同一個 session。
@MainActor
final class AgentController {
    private let store: TranscriptStore
    private let agent: CodexAgent?
    private let metrics: MetricsStore
    private let polisher: TranscriptPolisher
    private let speakers: SpeakerTimeline
    private let isMeeting: () -> Bool
    private let sources = SourceTracker()
    private let screenCapturer = Capturer()
    /// /name 自定義命名要把聲紋送進 pump enroll（pump 延遲建立，用 provider 拿）。
    var pumpProvider: (() -> SpeakerDiarizerPump?)?
    private var threadID: String?  // codex session，app 重啟歸零
    /// 對話世代 — /clear 遞增；飛行中 turn 的 .thread event 帶舊世代回來時
    /// 不寫回 threadID（否則 submit 後 0.5-2s 內 /clear 會被默默復活 session）。
    private var convEpoch = 0

    init(store: TranscriptStore, agent: CodexAgent?, metrics: MetricsStore,
         polisher: TranscriptPolisher, speakers: SpeakerTimeline,
         isMeeting: @escaping () -> Bool = { false }) {
        self.store = store
        self.agent = agent
        self.metrics = metrics
        self.polisher = polisher
        self.speakers = speakers
        self.isMeeting = isMeeting
        // 分人關閉時不注入 resolver/canonicalizer — store 兩者維持 nil，
        // 講者切段（splitAtSpeakerChange）、回溯改名/補標全部自動短路，逐字稿走純連續流。
        guard diarizationEnabled else { return }
        // 同人判定：講者標籤正規化成字母 — 顯示名升級（講者 B → 伯恩）不撕塊
        store.speakerCanonicalizer = { [weak self] label in
            self?.speakers.canonicalLetter(for: label)
        }
        // 講者標籤延後到 polisher 取批時解析（diarizer 收斂比 final 慢，commit 當下查常落空）
        store.speakerResolver = { [weak self] range in
            guard let self else { return nil }
            let meeting = self.isMeeting()
            return self.speakers.dominantLabel(
                start: range.start.seconds, end: range.end.seconds,
                prefix: meeting ? "對方" : "講者",
                requireMultipleSpeakers: !meeting)
        }
    }

    /// 系統音訊有 ASR 結果（含 volatile）— 分人 speech gate 的訊號源。
    func noteSpeech() {
        store.lastSpeechAt = Date()
    }

    /// 辨識中的 volatile → overlay 灰字尾巴（打字機）。
    func appendVolatile(_ text: String) {
        store.setVolatile(text)
    }

    /// 每段定稿進逐字稿（顯示 + codex context），並戳 polisher 整理。
    /// 帶 timeRange 進 pending — 講者標籤在 polisher 取批時才解析（speakerResolver），
    /// 這裡只記 fallback 來源（前景 app）。locale 跟著進 pending（整理選對指令語言）。
    func appendFinal(_ text: String, locale: String, timeRange: CMTimeRange? = nil,
                     pieces: [(text: String, range: CMTimeRange)] = []) {
        store.commitFinal(text, locale: locale, source: sources.current(), timeRange: timeRange,
                          pieces: pieces)
        metrics.recordSegment(chars: text.count)
        if let timeRange { metrics.recordAudio(seconds: timeRange.duration.seconds) }  // 「每 10 分鐘花費」的分母
        polisher.nudge()
    }

    /// 會議模式：mic（你這側）的定稿 — 來源固定標「我」，不跟前景 app。
    func appendMicFinal(_ text: String, locale: String) {
        store.commitFinal(text, locale: locale, source: "我")
        metrics.recordSegment(chars: text.count)
        polisher.nudge()
    }

    /// 使用者在 overlay 打的指令 → codex（連同最近逐字稿 + 全部圈選素材，送出即消耗）。
    func submit(_ instruction: String) {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        if ["/clear", "/new"].contains(instruction.lowercased()) {
            clearConversation()
            return
        }
        // /name A 王小明 — 使用者直接命名匿名講者並註冊聲紋。user 確認是最高權威，
        // 不走 enricher 的兩輪一致閘；之後跨 session 純聲學認人。
        if instruction.lowercased().hasPrefix("/name") {
            nameSpeaker(String(instruction.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            return
        }
        let attachments = store.attachments
        store.clearAttachments()
        run(instruction: instruction, attachments: attachments, label: instruction)
    }

    /// /name <講者字母> <名字>：撈該講者近期聲音片段送 enroll。
    /// 樣本不足（<3s）pump 會記 log 跳過 — feed 提示寫明「樣本足夠即生效」。
    private func nameSpeaker(_ args: String) {
        guard diarizationEnabled else {
            store.appendError("講者分人已關閉 — 重開請以 --diarize 啟動")
            return
        }
        let usage = "用法：/name <講者字母> <名字>，例如 /name A 王小明"
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { store.appendError(usage); return }
        let letter = parts[0].replacingOccurrences(of: "講者", with: "")
            .replacingOccurrences(of: "對方", with: "")
            .trimmingCharacters(in: .whitespaces).uppercased()
        let name = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard letter.count == 1, ("A"..."Z").contains(letter), !name.isEmpty else {
            store.appendError(usage); return
        }
        let ranges = speakers.segmentRanges(forLetter: letter)
        guard !ranges.isEmpty else {
            store.appendError("找不到講者 \(letter) 的聲音片段 — 畫面上要先出現過「講者 \(letter)」")
            return
        }
        guard let pump = pumpProvider?() else {
            store.appendError("分人引擎還沒啟動（要先有語音在播）")
            return
        }
        pump.requestEnroll(name: name, ranges: ranges)
        store.upsertStep(id: "name-\(letter)-\(name)",
                         title: "講者 \(letter) → \(name)（聲紋註冊中，樣本足夠即生效）",
                         running: false, failed: false)
        store.touchOverlay()
    }

    /// 畫面上活躍的匿名講者字母（右鍵「命名講者 X…」選單用）。
    func anonymousLetters() -> [String] { speakers.anonymousLetters }

    /// 重開對話：清 feed + 畫面逐字稿、丟 codex session — 下一輪 fresh session
    ///（歸檔的逐字稿不動，圈選素材保留）。
    func clearConversation() {
        convEpoch += 1
        threadID = nil
        store.clearFeed()
        store.clearTranscript()
    }

    /// chip 快捷動作：只消耗那一顆 chip。
    func quickAction(_ action: QuickAction, on asset: Asset) {
        store.removeAttachment(asset)
        let what = switch asset.kind {
        case .image: "截圖"
        case .text: "圈選文字"
        case .file: "檔案"
        }
        run(instruction: action.instruction, attachments: [asset],
            label: "\(action.label)（\(what)）")
    }

    /// Finder 拖進 overlay 的檔案 → chips。圖片檔 stage 進 captures 直接走 -i（零解碼 —
    /// 48MP 照片在主執行緒 decode+re-encode 會凍 4 秒），其他檔案留路徑讓 codex 自己讀。
    /// 瀏覽器拖進來的連結（dropDestination 連 public.url 都收）變文字 chip，codex 自己抓。
    func addDroppedFiles(_ urls: [URL]) {
        for url in urls {
            guard url.isFileURL else {
                let s = url.absoluteString
                guard !s.isEmpty else { continue }
                store.addAttachment(Asset(kind: .text(s), source: url.host() ?? "連結",
                                          capturedAt: Date()))
                continue
            }
            let name = url.lastPathComponent
            let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            // stage 失敗就降級成一般檔案（路徑走 env 進 prompt，不碰 -i 的引號拼接）
            let path = isImage ? (stageImage(url) ?? url.path) : url.path
            store.addAttachment(Asset(kind: .file(path), source: name, capturedAt: Date()))
        }
    }

    /// 拖入的圖片檔 clone 進 ~/.kilo/captures（APFS COW，免解碼免等）— 原檔之後被移走
    /// 也不影響；檔名自家產（UUID + 淨化過的副檔名），拼進 codex -i 的單引號才安全。
    private func stageImage(_ url: URL) -> String? {
        let dir = kiloWorkdir + "/captures"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ext = url.pathExtension.filter { $0.isLetter || $0.isNumber }
        let dest = dir + "/drop-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
        do {
            try FileManager.default.copyItem(atPath: url.path, toPath: dest)
            return dest
        } catch {
            Telemetry.shake.error("stage dropped image failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 截「游標所在的螢幕」整幅 → 變成一顆 chip（不自動送出，可疊指令、跟其他 chip 組合）。
    func captureScreen() {
        Task {
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main else { return }
            let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero } ?? screen).frame.height
            let f = screen.frame
            var info = OverlayInfo()
            info.app = "螢幕截圖"
            info.frame = CGRect(x: f.origin.x, y: primaryH - f.maxY, width: f.width, height: f.height)
            if let asset = await screenCapturer.capture(info: info) {
                store.addAttachment(asset)
                Telemetry.shake.info("full-screen capture added")
            }
        }
    }

    /// 組裝 + 跑一輪：文字素材進 prompt、截圖存檔走 -i。
    private func run(instruction: String, attachments: [Asset], label: String) {
        guard !store.thinking else { return }  // turn-at-a-time
        store.beginTurn(label)
        guard let agent else {
            store.appendError("沒有 codex agent（缺 OpenAI key）")
            return
        }

        var fullInstruction = instruction
        let texts = attachments.compactMap { a -> String? in
            guard case .text(let s) = a.kind else { return nil }
            return "（\(a.source)）\n\(s)"
        }
        if !texts.isEmpty {
            fullInstruction += "\n\n（使用者圈選的畫面文字）\n" + texts.joined(separator: "\n---\n")
        }
        // .file 分流：只有自家 stage 出來的 captures 路徑能進 -i（引號拼接安全），
        // 其他一律列路徑讓 codex 自己讀（走 env，不碰命令字串）
        var stagedImages: [String] = []
        var files: [String] = []
        for a in attachments {
            guard case .file(let p) = a.kind else { continue }
            if p.hasPrefix(kiloWorkdir + "/captures/") { stagedImages.append(p) } else { files.append(p) }
        }
        if !files.isEmpty {
            fullInstruction += "\n\n（使用者拖入的檔案，用工具直接讀這些路徑）\n" + files.joined(separator: "\n")
        }
        let imagePaths = saveImages(attachments) + stagedImages
        if !attachments.isEmpty {
            var parts: [String] = []
            if !imagePaths.isEmpty { parts.append("\(imagePaths.count) 張圖") }
            if !texts.isEmpty { parts.append("\(texts.count) 段文字") }
            if !files.isEmpty { parts.append("\(files.count) 個檔案") }
            store.upsertStep(id: "attach-\(Date().timeIntervalSince1970)",
                             title: "📎 " + parts.joined(separator: "、"),
                             running: false, failed: false)
        }

        store.setThinking(true)
        let transcript = store.context
        let epoch = convEpoch
        Task {
            let start = Date()
            var result = await runTurn(agent, instruction: fullInstruction,
                                       transcript: transcript, resume: threadID,
                                       images: imagePaths, epoch: epoch)

            // resume 失敗（session 被 GC / 重開機後不存在）且還沒有任何回覆 → 重開新 session 再試一次
            if result.error != nil, threadID != nil, !result.gotMessage, epoch == convEpoch {
                threadID = nil
                store.upsertStep(id: "resume-retry", title: "session 失效，重開新對話",
                                 running: false, failed: false)
                result = await runTurn(agent, instruction: fullInstruction,
                                       transcript: transcript, resume: nil,
                                       images: imagePaths, epoch: epoch)
            }

            if let error = result.error {
                store.appendError(error.localizedDescription)
            } else if !result.gotMessage {
                store.appendError("codex 沒回應")
            }
            metrics.recordCodex(latency: Date().timeIntervalSince(start),
                                failed: result.error != nil)
            store.setThinking(false)
        }
    }

    /// 圈選截圖存到 ~/.kilo/captures/（codex 之後也能自己讀），回傳路徑。
    private func saveImages(_ attachments: [Asset]) -> [String] {
        let dir = kiloWorkdir + "/captures"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return attachments.compactMap { a in
            guard let data = a.pngData() else { return nil }
            let path = dir + "/capture-\(a.id.uuidString).png"
            do {
                try data.write(to: URL(fileURLWithPath: path))
                return path
            } catch {
                Telemetry.shake.error("save capture failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// 跑一輪 codex turn，事件直灌 feed；回傳是否收到回覆與錯誤。
    private func runTurn(_ agent: CodexAgent, instruction: String, transcript: String,
                         resume: String?, images: [String] = [],
                         epoch: Int) async -> (gotMessage: Bool, error: Error?) {
        var got = false
        do {
            for try await ev in agent.stream(instruction: instruction,
                                             transcript: transcript, resume: resume, images: images) {
                switch ev {
                case .thread(let id):
                    if epoch == convEpoch { threadID = id }  // /clear 之後的舊 turn 不復活 session
                case .step(let id, let title, let running, let failed):
                    store.upsertStep(id: id, title: title, running: running, failed: failed)
                case .message(let text):
                    got = true
                    store.appendReply(text)
                case .usage(let p, let cached, let comp):
                    metrics.recordLLMUsage(prompt: p, cached: cached, completion: comp)  // Kilo 問答也計量
                }
            }
            return (got, nil)
        } catch {
            return (got, error)
        }
    }
}
