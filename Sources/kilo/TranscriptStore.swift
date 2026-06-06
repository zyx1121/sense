import Foundation

/// 逐字稿分段 + Kilo 回應。window 顯示、codex agent 讀來思考。
@MainActor @Observable
final class TranscriptStore {
    private(set) var segments: [String] = []   // 每段一個 finalized 逐字稿
    private(set) var reply: String?            // Kilo 最近一次回應
    private(set) var thinking = false

    func addSegment(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        segments.append(t)
        if segments.count > 60 { segments.removeFirst(segments.count - 60) }
    }

    func setReply(_ r: String) { reply = r }
    func setThinking(_ b: Bool) { thinking = b }

    /// 餵給 codex 的 context（最近 30 段）。
    var context: String { segments.suffix(30).joined(separator: "\n") }
}
