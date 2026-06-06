import Foundation

/// overlay input → codex agent。逐字稿存在 TranscriptStore（也是 codex 的 context）。
@MainActor
final class AgentController {
    private let store: TranscriptStore
    private let agent: CodexAgent?
    private let metrics: MetricsStore

    init(store: TranscriptStore, agent: CodexAgent?, metrics: MetricsStore) {
        self.store = store
        self.agent = agent
        self.metrics = metrics
    }

    /// 每段定稿進逐字稿（顯示 + codex context）。
    func appendFinal(_ text: String) {
        store.addSegment(text)
        metrics.recordSegment(chars: text.count)
    }

    /// 使用者在 overlay 打的指令 → codex（連同最近逐字稿）。
    func submit(_ instruction: String) {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        guard let agent else {
            store.setReply("⚠️ 沒有 codex agent（缺 OpenAI key）")
            return
        }
        store.setThinking(true)
        let transcript = store.context
        let store = self.store
        let metrics = self.metrics
        Task {
            let start = Date()
            do {
                let result = try await agent.run(instruction: instruction, transcript: transcript)
                store.setReply(result.text.isEmpty ? "（codex 沒回應）" : result.text)
                metrics.recordCodex(latency: Date().timeIntervalSince(start), failed: false)
            } catch {
                store.setReply("⚠️ \(error.localizedDescription)")
                metrics.recordCodex(latency: Date().timeIntervalSince(start), failed: true)
            }
            store.setThinking(false)
        }
    }
}
