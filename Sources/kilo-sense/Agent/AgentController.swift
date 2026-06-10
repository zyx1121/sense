import AppKit
import Foundation

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
    private let sources = SourceTracker()
    private let screenCapturer = Capturer()
    private var threadID: String?  // codex session，app 重啟歸零

    init(store: TranscriptStore, agent: CodexAgent?, metrics: MetricsStore, polisher: TranscriptPolisher) {
        self.store = store
        self.agent = agent
        self.metrics = metrics
        self.polisher = polisher
    }

    /// 辨識中的 volatile → overlay 灰字尾巴（打字機）。
    func appendVolatile(_ text: String) {
        store.setVolatile(text)
    }

    /// 每段定稿進逐字稿（顯示 + codex context），並戳 polisher 整理。
    /// locale 跟著進 pending（整理選對指令語言）、來源（前景 app）跟著進歸檔。
    func appendFinal(_ text: String, locale: String) {
        store.commitFinal(text, locale: locale, source: sources.current())
        metrics.recordSegment(chars: text.count)
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
        let attachments = store.attachments
        store.clearAttachments()
        run(instruction: instruction, attachments: attachments, label: instruction)
    }

    /// chip 快捷動作：只消耗那一顆 chip。
    func quickAction(_ action: QuickAction, on asset: Asset) {
        store.removeAttachment(asset)
        run(instruction: action.instruction, attachments: [asset],
            label: "\(action.label)（\(asset.typeLabel == "image" ? "截圖" : "圈選文字")）")
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
        let imagePaths = saveImages(attachments)
        if !attachments.isEmpty {
            store.upsertStep(id: "attach-\(Date().timeIntervalSince1970)",
                             title: "📎 \(imagePaths.count) 張截圖、\(texts.count) 段文字",
                             running: false, failed: false)
        }

        store.setThinking(true)
        let transcript = store.context
        Task {
            let start = Date()
            var result = await runTurn(agent, instruction: fullInstruction,
                                       transcript: transcript, resume: threadID, images: imagePaths)

            // resume 失敗（session 被 GC / 重開機後不存在）且還沒有任何回覆 → 重開新 session 再試一次
            if result.error != nil, threadID != nil, !result.gotMessage {
                threadID = nil
                store.upsertStep(id: "resume-retry", title: "session 失效，重開新對話",
                                 running: false, failed: false)
                result = await runTurn(agent, instruction: fullInstruction,
                                       transcript: transcript, resume: nil, images: imagePaths)
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
                         resume: String?, images: [String] = []) async -> (gotMessage: Bool, error: Error?) {
        var got = false
        do {
            for try await ev in agent.stream(instruction: instruction,
                                             transcript: transcript, resume: resume, images: images) {
                switch ev {
                case .thread(let id):
                    threadID = id
                case .step(let id, let title, let running, let failed):
                    store.upsertStep(id: id, title: title, running: running, failed: failed)
                case .message(let text):
                    got = true
                    store.appendReply(text)
                }
            }
            return (got, nil)
        } catch {
            return (got, error)
        }
    }
}
