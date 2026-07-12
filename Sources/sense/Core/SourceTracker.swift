import AppKit
import ApplicationServices

/// 逐字稿來源標記：前景 app 名 + focused window 標題（瀏覽器分頁標題會跟著 window title 走）。
/// 需要 Accessibility（shake 已申請同一權限）。
@MainActor
final class SourceTracker {
    /// 如 "Safari: 半導體產業史 - YouTube"；拿不到標題就只給 app 名。
    func current() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName else { return nil }
        var win: CFTypeRef?
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let w = win, CFGetTypeID(w) == AXUIElementGetTypeID() else { return name }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
              let t = title as? String, !t.isEmpty else { return name }
        return "\(name): \(t)"
    }
}
