import Foundation

/// overlay input → codex agent。維護最近逐字稿當 context，submit 指令時呼叫 codex。
@MainActor @Observable
final class AgentController {
    private let store: SummaryStore
    private let agent: CodexAgent?
    private var recentTranscript = ""
    private(set) var thinking = false

    init(store: SummaryStore, agent: CodexAgent?) {
        self.store = store
        self.agent = agent
    }

    /// 每段定稿累積進 rolling context（capped）。
    func appendFinal(_ text: String) {
        recentTranscript += text
        if recentTranscript.count > 2000 {
            recentTranscript = String(recentTranscript.suffix(2000))
        }
    }

    /// 使用者在 overlay 打的指令 → codex（連同最近逐字稿）。
    func submit(_ instruction: String) {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        guard let agent else {
            store.add("⚠️ 沒有 codex agent（缺 OpenAI key）")
            return
        }
        thinking = true
        let transcript = recentTranscript
        Task {
            do {
                let result = try await agent.run(instruction: instruction, transcript: transcript)
                store.add(result.text.isEmpty ? "（codex 沒有回應）" : result.text)
            } catch {
                store.add("⚠️ \(error.localizedDescription)")
            }
            thinking = false
        }
    }
}
