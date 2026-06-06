import Foundation

/// Kilo feed 的一個步驟：使用者指令 / tool 執行 / 回應 / 錯誤。
struct AgentStep: Identifiable, Equatable {
    enum Kind: Equatable { case user, tool, reply, error }
    let id: String
    let kind: Kind
    var text: String                 // raw 全文（tool = title）
    var rendered: AttributedString   // reply: markdown 解析後；其他 = 原文
    var shownChars: Int              // reply 打字機已顯示字元數；其他 = 全長
    var running = false              // tool 進行中
    var failed = false               // tool exit != 0

    init(id: String, kind: Kind, text: String, revealed: Bool, running: Bool = false, failed: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.rendered = kind == .reply ? renderMarkdown(text) : AttributedString(text)
        self.shownChars = revealed ? self.rendered.characters.count : 0
        self.running = running
        self.failed = failed
    }
}

/// reply 的 markdown → AttributedString。解析放 append 時做一次，
/// 打字機切「解析後」的前綴 — streaming 中不會先閃裸 `**` 再變粗體。
/// 1. `- ` / `* ` 列表轉 `•`（inline 模式不排版 block，自己轉）
/// 2. inline 解析：bold / italic / code，保留換行
/// 3. 檔案路徑自動標成 link（點擊走 openFeedLink 的 workdir 解析）
private func renderMarkdown(_ s: String) -> AttributedString {
    let bulleted = s.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        let body = line.drop(while: { $0 == " " })
        guard body.hasPrefix("- ") || body.hasPrefix("* ") else { return String(line) }
        let indent = String(repeating: " ", count: line.count - body.count)
        return "\(indent)•  \(body.dropFirst(2))"
    }.joined(separator: "\n")

    var a = (try? AttributedString(
        markdown: bulleted,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(bulleted)
    linkifyPaths(&a)
    return a
}

/// 長得像路徑的片段標成 link + 底線；markdown 原生 link 也補底線，affordance 一致。
private func linkifyPaths(_ a: inout AttributedString) {
    let s = String(a.characters)
    // 副檔名錨定（檔名可含中文）+ ~/、/ 開頭的目錄路徑
    let ext = /[\p{L}\p{N}._~\-\/]+\.(?:md|txt|json|ya?ml|toml|csv|log|swift|py|sh)/
    let dir = /(?:~|\/)[A-Za-z0-9._\-\/]+/
    var ranges = s.ranges(of: ext)
    for r in s.ranges(of: dir) where !ranges.contains(where: { $0.overlaps(r) }) {
        ranges.append(r)
    }

    let chars = a.characters
    for r in ranges {
        var path = String(s[r])
        while path.hasSuffix(".") || path.hasSuffix(",") { path.removeLast() }  // 句尾標點不算
        guard !path.isEmpty else { continue }
        let lo = chars.index(chars.startIndex, offsetBy: s.distance(from: s.startIndex, to: r.lowerBound))
        let hi = chars.index(lo, offsetBy: path.count)
        let ar = lo..<hi
        guard !a[ar].runs.contains(where: { $0.link != nil }) else { continue }  // 不蓋 markdown link
        a[ar].link = URL(string: path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }
    for run in a.runs where run.link != nil {
        a[run.range].underlineStyle = .single
    }
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

    /// shake 圈選收進來、等下一輪 codex 帶上的素材。
    private(set) var attachments: [Asset] = []

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

    /// feed 內容長度（含打字機進度），view 拿來觸發 auto-scroll。
    var feedLength: Int { feed.reduce(feed.count) { $0 + $1.shownChars } }

    /// 新 turn：指令追加進 feed（歷史保留，可往回捲），不清舊步驟。
    func beginTurn(_ instruction: String) {
        stepSeq += 1
        feed.append(AgentStep(id: "user-\(stepSeq)", kind: .user, text: instruction, revealed: true))
        trimFeed()
    }

    /// tool 步驟進度：同 id 更新（in_progress → completed），新 id 追加。
    func upsertStep(id: String, title: String, running: Bool, failed: Bool) {
        if let i = feed.firstIndex(where: { $0.id == id }) {
            feed[i].text = title
            feed[i].rendered = AttributedString(title)
            feed[i].shownChars = title.count
            feed[i].running = running; feed[i].failed = failed
        } else {
            feed.append(AgentStep(id: id, kind: .tool, text: title, revealed: true,
                                  running: running, failed: failed))
        }
    }

    func appendReply(_ text: String) {
        stepSeq += 1
        feed.append(AgentStep(id: "reply-\(stepSeq)", kind: .reply, text: text, revealed: false))
        trimFeed()
        pumpReply()
    }

    func appendError(_ text: String) {
        stepSeq += 1
        feed.append(AgentStep(id: "err-\(stepSeq)", kind: .error, text: text, revealed: true))
    }

    func setThinking(_ b: Bool) { thinking = b }

    // MARK: - Attachments（shake 圈選素材）

    func addAttachment(_ a: Asset) { attachments.append(a) }
    func removeAttachment(_ a: Asset) { attachments.removeAll { $0.id == a.id } }
    func clearAttachments() { attachments.removeAll() }

    /// 歷史上限：太舊的步驟從頭丟（記憶體安全閥，捲回去看得到的範圍內夠用）。
    private func trimFeed() {
        if feed.count > 120 { feed.removeFirst(feed.count - 120) }
    }

    /// 打字機：依序把 reply step 的 shownChars 推進到全長（10ms/字）。
    private func pumpReply() {
        guard replyTask == nil else { return }
        replyTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let i = feed.firstIndex(where: {
                    $0.kind == .reply && $0.shownChars < $0.rendered.characters.count
                }) else { break }
                feed[i].shownChars += 1
                try? await Task.sleep(for: .milliseconds(10))
            }
            self?.replyTask = nil
        }
    }
}
