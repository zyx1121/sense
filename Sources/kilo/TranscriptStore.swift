import Foundation

/// Kilo feed 的一個步驟：使用者指令 / tool 執行 / 回應 / 錯誤。
struct AgentStep: Identifiable, Equatable {
    enum Kind: Equatable { case user, tool, reply, error }
    let id: String
    let kind: Kind
    var text: String       // 全文（tool = title）
    var shown: String      // reply 打字機已顯示的前綴；其他 kind == text
    var running = false    // tool 進行中
    var failed = false     // tool exit != 0
}

/// 接合兩段文字：兩側都是 ASCII 字母/數字才補空格（英文），CJK 直接相連。
private func glue(_ a: String, _ b: String) -> String {
    guard let last = a.last, let first = b.first else { return a + b }
    let wordy: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
    return wordy(last) && wordy(first) ? a + " " + b : a + b
}

/// 逐字稿連續文件流 + Kilo agent 步驟 feed。window 顯示、codex agent 讀來思考。
/// 逐字稿三層：polished（小模型整理過）→ pendingRaw(定稿待整理) → volatile（辨識中，打字機推進）。
@MainActor @Observable
final class TranscriptStore {
    private(set) var polished = ""
    private(set) var pendingRaw = ""
    private(set) var volatileShown = ""
    private var volatileTarget = ""
    private var volatileTask: Task<Void, Never>?

    private(set) var feed: [AgentStep] = []
    private(set) var thinking = false
    private var replyTask: Task<Void, Never>?
    private var stepSeq = 0

    var transcriptLength: Int { polished.count + pendingRaw.count + volatileShown.count }
    var transcriptEmpty: Bool { polished.isEmpty && pendingRaw.isEmpty && volatileShown.isEmpty }

    /// 餵給 codex 的 context（整理過 + 未整理 + 辨識中的尾端）。
    var context: String { String(glue(glue(polished, pendingRaw), volatileTarget).suffix(4000)) }

    // MARK: - 逐字稿

    func setVolatile(_ text: String) {
        volatileTarget = text
        pumpVolatile()
    }

    func commitFinal(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        volatileTask?.cancel(); volatileTask = nil
        volatileTarget = ""; volatileShown = ""
        guard !t.isEmpty else { return }
        pendingRaw = glue(pendingRaw, t)
        if pendingRaw.count > 12000 { pendingRaw = String(pendingRaw.suffix(9000)) }  // 無 polisher 時的安全閥
    }

    /// polisher 整理完一個 chunk：從 pendingRaw 頭部移掉 consumed 字、整理後文字接上 polished。
    func commitPolished(_ cleaned: String, consumed: Int) {
        pendingRaw = String(pendingRaw.dropFirst(min(consumed, pendingRaw.count)))
        let c = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        polished = polished.isEmpty ? c : glue(polished, c)
        if polished.count > 12000 { polished = String(polished.suffix(9000)) }
    }

    /// 打字機：volatileShown 逐字推進到 target（25ms/字）；辨識回頭改字就直接對齊。
    private func pumpVolatile() {
        guard volatileTask == nil else { return }
        volatileTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if volatileShown == volatileTarget { break }
                if volatileTarget.hasPrefix(volatileShown) {
                    volatileShown = String(volatileTarget.prefix(volatileShown.count + 1))
                } else {
                    volatileShown = volatileTarget
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            self?.volatileTask = nil
        }
    }

    // MARK: - Kilo feed

    /// 新 turn：清掉上一輪步驟，指令當第一個 step。
    func beginTurn(_ instruction: String) {
        replyTask?.cancel(); replyTask = nil
        stepSeq += 1
        feed = [AgentStep(id: "user-\(stepSeq)", kind: .user, text: instruction, shown: instruction)]
    }

    /// tool 步驟進度：同 id 更新（in_progress → completed），新 id 追加。
    func upsertStep(id: String, title: String, running: Bool, failed: Bool) {
        if let i = feed.firstIndex(where: { $0.id == id }) {
            feed[i].text = title; feed[i].shown = title
            feed[i].running = running; feed[i].failed = failed
        } else {
            feed.append(AgentStep(id: id, kind: .tool, text: title, shown: title,
                                  running: running, failed: failed))
        }
    }

    func appendReply(_ text: String) {
        stepSeq += 1
        feed.append(AgentStep(id: "reply-\(stepSeq)", kind: .reply, text: text, shown: ""))
        pumpReply()
    }

    func appendError(_ text: String) {
        stepSeq += 1
        feed.append(AgentStep(id: "err-\(stepSeq)", kind: .error, text: text, shown: text))
    }

    func setThinking(_ b: Bool) { thinking = b }

    /// 打字機：依序把 reply step 的 shown 推進到全文（10ms/字）。
    private func pumpReply() {
        guard replyTask == nil else { return }
        replyTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let i = feed.firstIndex(where: { $0.kind == .reply && $0.shown != $0.text }) else { break }
                feed[i].shown = String(feed[i].text.prefix(feed[i].shown.count + 1))
                try? await Task.sleep(for: .milliseconds(10))
            }
            self?.replyTask = nil
        }
    }
}
