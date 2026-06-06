import Foundation

/// overlay input → codex agent。逐字稿存在 TranscriptStore（也是 codex 的 context）。
/// 對話 history：記住 codex 的 thread id，每輪 `exec resume` 續同一個 session。
@MainActor
final class AgentController {
    private let store: TranscriptStore
    private let agent: CodexAgent?
    private let metrics: MetricsStore
    private let polisher: TranscriptPolisher
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
    func appendFinal(_ text: String) {
        store.commitFinal(text)
        metrics.recordSegment(chars: text.count)
        polisher.nudge()
    }

    /// 使用者在 overlay 打的指令 → codex（連同最近逐字稿 + shake 圈選素材）。事件邊到邊進 feed。
    func submit(_ instruction: String) {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !store.thinking else { return }  // turn-at-a-time
        store.beginTurn(instruction)
        guard let agent else {
            store.appendError("沒有 codex agent（缺 OpenAI key）")
            return
        }

        // shake 圈選素材：文字進 prompt、截圖存檔走 -i；送出即消耗
        let attachments = store.attachments
        store.clearAttachments()
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
