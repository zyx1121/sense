import Foundation

/// 三軌被動觀測的統一收斂層 — 視窗/app 活動、檔案操作、(之後) 媒體播放各自正規化進這裡。
/// agent turn 時 `snapshot()` 注入 codex 當「使用者當下在幹嘛」的環境 context；
/// 逐字稿歸檔用 `currentSource`（取代舊的 SourceTracker，格式相容）。
///
/// 刻意分兩種語意，否則 caller 搞不清一筆觀測是覆蓋還是累加：
/// - 前景 app/window、media 是「當前狀態」— latest-wins，後蓋前
/// - app 切換、檔案操作是「離散事件」— append 進 ring buffer，只留最近 N 筆
@MainActor @Observable
final class ObservationStore {
    // 當前狀態（latest-wins）
    private var foregroundApp: String?
    private var foregroundWindow: String?
    private var media: String?   // 軌2a 之後填：「▶ 標題 12:30/45:00」
    private var audible: [String] = []   // 軌2b：正在輸出音訊的 app（latest-wins）

    // 離散事件（append + ring buffer）
    private var recent: [String] = []
    private let recentCap = 24

    // MARK: - 寫入端（三軌 producer 各自呼叫）

    /// 軌1：前景 app/window 變了。app 真的換掉才往 ring buffer 記一筆「切到 X」，
    /// 同 app 內換視窗/分頁只更新當前狀態（title 會狂變，不能每次都記事件）。
    func observeForeground(app: String, window: String?) {
        let changed = app != foregroundApp || window != foregroundWindow
        if app != foregroundApp { append("切到 \(app)") }
        foregroundApp = app
        foregroundWindow = window
        if changed {
            Telemetry.observe.info("前景 \(app, privacy: .public)\(window.map { " — \($0)" } ?? "", privacy: .public)")
        }
    }

    /// 軌3：檔案操作離散事件，summary 形如「新增 ~/Desktop/報告.pdf」。
    func observeFile(_ summary: String) {
        append(summary)
    }

    /// 軌2a（之後）：媒體播放狀態，nil = 沒在播。
    func observeMedia(_ summary: String?) {
        media = summary
    }

    /// 軌2b：當前正在輸出音訊的 app 集合（latest-wins）。新發聲的 app 記一筆事件。
    func observeAudible(_ apps: [String]) {
        guard apps != audible else { return }
        for app in apps where !audible.contains(app) { append("\(app) 開始發聲") }
        audible = apps
        Telemetry.observe.info("發聲中：\(apps.isEmpty ? "(無)" : apps.joined(separator: ", "), privacy: .public)")
    }

    private func append(_ text: String) {
        guard recent.last != text else { return }   // 連續相同去重（FSEvents 改名會雙發等）
        recent.append(text)
        if recent.count > recentCap { recent.removeFirst(recent.count - recentCap) }
        Telemetry.observe.info("\(text, privacy: .public)")
    }

    // MARK: - 讀取端（agent / 歸檔）

    /// 逐字稿歸檔出處 — 取代 SourceTracker.current()，格式相容（"Safari: 標題" / 只有 app 名）。
    var currentSource: String? {
        guard let app = foregroundApp else { return nil }
        guard let w = foregroundWindow, !w.isEmpty else { return app }
        return "\(app): \(w)"
    }

    /// agent turn 注入的當下環境快照。完全沒訊號時回 nil（prompt 不掛空段）。
    func snapshot(recentLimit: Int = 8) -> String? {
        var lines: [String] = []
        if let app = foregroundApp {
            lines.append("前景：\(app)" + (foregroundWindow.map { " — \($0)" } ?? ""))
        }
        if !audible.isEmpty { lines.append("發聲中：\(audible.joined(separator: ", "))") }
        if let media { lines.append("播放：\(media)") }
        let tail = recent.suffix(recentLimit)
        if !tail.isEmpty {
            lines.append("最近：")
            lines.append(contentsOf: tail.map { "- \($0)" })
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
