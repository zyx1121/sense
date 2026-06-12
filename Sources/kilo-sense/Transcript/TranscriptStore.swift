import CoreMedia
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

/// 接合兩段文字：ASCII 字詞間、英文句點後接字詞要補空格（"2017." + "It" → "2017. It"），CJK 直接相連。
/// internal — PushToTalk 拼輸入框草稿用同一套規則。
func glue(_ a: String, _ b: String) -> String {
    guard let last = a.last, let first = b.first else { return a + b }
    let wordy: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
    if (wordy(last) || ".!?,".contains(last)) && wordy(first) { return a + " " + b }
    return a + b
}

/// 待整理的一段定稿 — 帶語言標籤（polisher 按語言分批整理，指令語言跟著走才不會被翻譯）、
/// 來源（前景 app / 視窗標題，歸檔時標出處）與音訊時間範圍（講者標籤延後解析用）。
struct PendingSegment {
    let locale: String   // bcp47，如 "zh-TW"
    let text: String
    let source: String?  // fallback 來源（前景 app）；講者標籤在讀取時才解析
    var timeRange: CMTimeRange? = nil
}

/// 逐字稿連續文件流 + Kilo agent 步驟 feed。window 顯示、codex agent 讀來思考。
/// 逐字稿三層：polished（小模型整理過）→ pending（定稿待整理，帶 locale）→ volatile（辨識中，打字機推進）。
@MainActor @Observable
final class TranscriptStore {
    private(set) var polished = ""
    private(set) var pending: [PendingSegment] = []
    private(set) var volatileShown = ""
    private var volatileTarget = ""
    private var volatileTask: Task<Void, Never>?

    /// 顯示與 codex context 用的待整理全文。
    var pendingRaw: String { pending.reduce("") { glue($0, $1.text) } }

    private(set) var feed: [AgentStep] = []
    private(set) var thinking = false
    private var replyTask: Task<Void, Never>?
    private var stepSeq = 0

    /// shake 圈選收進來、等下一輪 codex 帶上的素材。
    private(set) var attachments: [Asset] = []

    // — PTT（按住右 ⇧ 說話）：草稿放 store 才能讓語音注入；view 雙向綁定同一份 —
    var inputDraft = ""
    var pttRecording = false
    /// PTT 放開後的尾段窗（遲到 final 還算 PTT 的）— 會議模式靠這個避開「對 Kilo 說的話進會議記錄」。
    var pttTailUntil = Date.distantPast

    /// 系統音訊最近一次 ASR 結果（volatile 也算）— 分人的 speech gate 用：有語音才餵 diarizer。
    var lastSpeechAt = Date.distantPast

    /// 講者標籤解析器（AgentController 注入）。在 firstPendingRun 讀取時才呼叫 —
    /// diarizer 收斂比 ASR final 慢 ~0.3-10s，commit 當下查常落空；
    /// polisher 取批至少在 4s idle / 湊字之後，那時 segment 已就位。
    var speakerResolver: ((CMTimeRange) -> String?)?

    /// 近期整理完的輪替（講者標籤 + 內容）— AttributionEnricher 的原料。
    private(set) var recentTurns: [(source: String?, text: String)] = []
    private(set) var turnsVersion = 0

    /// 畫面世代 — 「清除逐字稿」遞增；清除瞬間還在飛的 polish 批帶著舊世代回來，
    /// 只進歸檔不再上畫面（不擋歸檔，擋復活）。
    private(set) var transcriptEpoch = 0

    /// 清畫面開新段落：已歸檔的不動（~/.kilo/transcripts 永遠完整），只清顯示與待整理層。
    func clearTranscript() {
        volatileTask?.cancel(); volatileTask = nil
        polished = ""; pending = []; volatileTarget = ""; volatileShown = ""
        lastPolishedLocale = nil
        recentTurns = []
        transcriptEpoch += 1
        touchOverlay()
    }

    // — overlay 縮放：⌘= / ⌘- / ⌘0（狀態欄選單同款入口），跨啟動記住 —
    private(set) var uiScale: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "overlayScale")
        return v == 0 ? 1 : CGFloat(min(max(v, 0.8), 1.6))
    }()

    func zoom(_ delta: CGFloat) {
        uiScale = min(max(uiScale + delta, 0.8), 1.6)
        UserDefaults.standard.set(Double(uiScale), forKey: "overlayScale")
        touchOverlay()
    }

    func zoomReset() {
        uiScale = 1
        UserDefaults.standard.set(1.0, forKey: "overlayScale")
        touchOverlay()
    }

    // — 釘選：釘住就不閒置收合（header pin 鈕切換，跨啟動記住）—
    private(set) var pinned = UserDefaults.standard.bool(forKey: "overlayPinned")

    func togglePin() {
        pinned.toggle()
        UserDefaults.standard.set(pinned, forKey: "overlayPinned")
        touchOverlay()  // 取消釘選的當下重新起算閒置計時
    }

    // — overlay 可見性：shake / 打字 / agent 活動 / hover 續命，閒置自動收合 —
    // 聲音（逐字稿流入）刻意不續命：那是 notch 的展開條件，overlay 只跟「使用者在動它」走。
    private(set) var overlayShown = true
    private var overlayHideTask: Task<Void, Never>?
    private let overlayIdleSeconds: Double = 30

    var transcriptLength: Int { polished.count + pendingRaw.count + volatileShown.count }
    var transcriptEmpty: Bool { polished.isEmpty && pendingRaw.isEmpty && volatileShown.isEmpty }

    /// 餵給 codex 的 context（整理過 + 未整理 + 辨識中的尾端）。
    var context: String { String(glue(glue(polished, pendingRaw), volatileTarget).suffix(4000)) }

    // MARK: - 逐字稿

    func setVolatile(_ text: String) {
        volatileTarget = text
        pumpVolatile()
    }

    func commitFinal(_ text: String, locale: String, source: String? = nil,
                     timeRange: CMTimeRange? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        volatileTask?.cancel(); volatileTask = nil
        volatileTarget = ""; volatileShown = ""
        guard !t.isEmpty else { return }
        pending.append(PendingSegment(locale: locale, text: t, source: source,
                                      timeRange: timeRange))  // 一筆 final 一段，不合併 — polisher 按段消耗才不會吃到飛中的新字
        while pendingRaw.count > 12000, !pending.isEmpty { pending.removeFirst() }  // 無 polisher 時的安全閥
    }

    /// pending 開頭「同語言、同來源的連續段」— polisher 的一個整理批次。
    /// 來源也斷批：會議模式我（mic）/ 對方（系統音）交錯時，批次混源會讓歸檔的
    /// 出處標頭張冠李戴。boundary = 後面接著別的語言或來源（提示 polisher 別等湊字數、快點沖掉）。
    /// 來源在這裡（讀取時）才解析講者標籤 — 見 speakerResolver 註解。
    func firstPendingRun() -> (locale: String, text: String, segments: Int, boundary: Bool, source: String?)? {
        guard let first = pending.first else { return nil }
        let firstSource = resolvedSource(first)
        var text = first.text
        var n = 1
        for seg in pending.dropFirst() {
            guard seg.locale == first.locale, resolvedSource(seg) == firstSource else {
                return (first.locale, text, n, true, firstSource)
            }
            text = glue(text, seg.text)
            n += 1
        }
        return (first.locale, text, n, false, firstSource)
    }

    /// 段落的有效來源：講者標籤（時間範圍查得到）優先，否則 fallback 收錄當下的前景 app。
    private func resolvedSource(_ seg: PendingSegment) -> String? {
        if let tr = seg.timeRange, let label = speakerResolver?(tr) { return label }
        return seg.source
    }

    private var lastPolishedLocale: String?

    /// polisher 整理完一批：移掉消耗的段、整理後文字接上 polished。
    /// 段落空行由這裡的確定性後處理保證（模型實測不穩定遵守）；批次接合規則：
    /// 換語言一律空行（語言切換必是新段 — 沒標點的雜訊批才不會把下一語言黏進同一行）、
    /// 同語言看句末標點（有 → 空行；無 → 斷句續接）。
    @discardableResult
    func commitPolished(_ cleaned: String, locale: String, consumedSegments: Int,
                        source: String? = nil, epoch: Int? = nil) -> String? {
        pending.removeFirst(min(consumedSegments, pending.count))
        let c = breakLines(trimOverlap(cleaned.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard !c.isEmpty else { return nil }
        if let epoch, epoch != transcriptEpoch { return c }  // 清除後才回來的批：歸檔照走、畫面不復活
        let sentenceEnd = polished.last.map { "。！？.!?…".contains($0) } ?? false
        let langChanged = lastPolishedLocale != nil && lastPolishedLocale != locale
        polished = polished.isEmpty ? c : ((sentenceEnd || langChanged) ? polished + "\n\n" + c : glue(polished, c))
        lastPolishedLocale = locale
        if polished.count > 12000 { polished = String(polished.suffix(9000)) }
        recentTurns.append((source, c))  // 輪替史 — enricher 推角色/人名的原料
        if recentTurns.count > 30 { recentTurns.removeFirst(recentTurns.count - 30) }
        turnsVersion += 1
        return c  // 實際上稿的文字（裁 echo、斷行後）— 給歸檔用
    }

    /// 句末標點後斷行：中文「。！？」直接斷；英文「. ! ?」後接空格才斷（"U.S. Army" 會誤斷，接受）。
    /// 最後統一成「段落間空一行」（\n\n）— 模型自己給的換行也一併正規化，鬆緊一致。
    private func breakLines(_ s: String) -> String {
        let chars = Array(s)
        var out = String()
        out.reserveCapacity(chars.count + 16)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            out.append(c)
            let cjkEnd = "。！？".contains(c)
            let asciiEnd = ".!?".contains(c) && i + 1 < chars.count && chars[i + 1] == " "
            if cjkEnd || asciiEnd {
                var j = i + 1
                while j < chars.count, chars[j] == " " { j += 1 }   // 句後空白換成斷行
                if j < chars.count, chars[j] != "\n" { out.append("\n") }
                i = j
                continue
            }
            i += 1
        }
        return out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// 小模型偶爾把「前文參考」照抄進輸出 — 拿 polished 結尾跟新輸出開頭做
    /// suffix-prefix overlap，重疊 ≥8 字就裁掉（防重複句的程式碼層防線）。
    private func trimOverlap(_ incoming: String) -> String {
        let tail = String(polished.suffix(200))
        guard !tail.isEmpty, !incoming.isEmpty else { return incoming }
        var len = min(tail.count, incoming.count)
        while len >= 8 {
            if tail.hasSuffix(String(incoming.prefix(len))) {
                return String(incoming.dropFirst(len)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            len -= 1
        }
        return incoming
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
        touchOverlay()  // 打字送指令 = 在動 overlay，展開並重置閒置計時
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
        touchOverlay()
    }

    func appendError(_ text: String) {
        stepSeq += 1
        feed.append(AgentStep(id: "err-\(stepSeq)", kind: .error, text: text, revealed: true))
    }

    func setThinking(_ b: Bool) { thinking = b }

    /// 清空 Kilo 對話 feed（/clear、右鍵「清除對話」）— 步驟與打字機歸零；逐字稿與圈選素材不動。
    /// 還在飛的 turn 事件會落進清空後的 feed — 接受（那是新對話前最後的殘響）。
    func clearFeed() {
        replyTask?.cancel(); replyTask = nil
        feed = []
        touchOverlay()
    }

    // MARK: - Overlay 可見性

    /// 有人在動 overlay：展開 + 重置閒置計時；agent 還在跑就不收。
    func touchOverlay() {
        overlayShown = true
        overlayHideTask?.cancel()
        overlayHideTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(overlayIdleSeconds))
                guard !Task.isCancelled else { return }
                if thinking || pinned { continue }  // 回覆進行中 / 釘住不收，醒著等下一輪閒置
                overlayShown = false
                return
            }
        }
    }

    // MARK: - Attachments（shake 圈選素材）

    func addAttachment(_ a: Asset) {
        attachments.append(a)
        touchOverlay()
    }
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
