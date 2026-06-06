import Foundation

/// overlay input → codex agent。逐字稿存在 TranscriptStore（也是 codex 的 context）。
@MainActor
final class AgentController {
    private let store: TranscriptStore
    private let agent: CodexAgent?
    private let metrics: MetricsStore
    private let polisher: TranscriptPolisher

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

    /// 使用者在 overlay 打的指令 → codex（連同最近逐字稿）。事件邊到邊進 feed。
    func submit(_ instruction: String) {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !store.thinking else { return }  // turn-at-a-time
        store.beginTurn(instruction)
        guard let agent else {
            store.appendError("沒有 codex agent（缺 OpenAI key）")
            return
        }
        store.setThinking(true)
        let transcript = store.context
        let store = self.store
        let metrics = self.metrics
        Task {
            let start = Date()
            var failed = false
            var gotMessage = false
            do {
                for try await ev in agent.stream(instruction: instruction, transcript: transcript) {
                    switch ev {
                    case .step(let id, let title, let running, let f):
                        store.upsertStep(id: id, title: title, running: running, failed: f)
                    case .message(let text):
                        gotMessage = true
                        store.appendReply(text)
                    }
                }
                if !gotMessage { store.appendError("codex 沒回應") }
            } catch {
                failed = true
                store.appendError(error.localizedDescription)
            }
            metrics.recordCodex(latency: Date().timeIntervalSince(start), failed: failed)
            store.setThinking(false)
        }
    }
}
