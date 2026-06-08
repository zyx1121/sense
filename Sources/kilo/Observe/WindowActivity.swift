import AppKit
import ApplicationServices

/// 軌1：事件驅動的前景 app/window 追蹤，取代輪詢式 SourceTracker。
/// - NSWorkspace 通知抓「app 切換」→ 把 AXObserver 重綁到新前景 app
/// - 對當前前景 app 維持單一 AXObserver，訂閱 focused-window / title-changed
///   → 同 app 內換視窗、分頁標題變（YouTube 換片、Finder 換資料夾、Meet 換會議）即時更新
///
/// 任一時刻只綁一個 observer（前景 pid），切 app 就拆舊建新 — 我們只 care 使用者「當下」看什麼，
/// 不需對全部 app 各建 observer。需 Accessibility（shake 已申請）；沒授權時 degrade 成只給 app 名。
@MainActor
final class WindowActivity {
    private let store: ObservationStore
    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    private var observedName = ""
    private var refreshTimer: Timer?

    init(store: ObservationStore) { self.store = store }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let name = app.localizedName else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.rebind(pid: pid, name: name) }
        }
        if let app = NSWorkspace.shared.frontmostApplication, let name = app.localizedName {
            rebind(pid: app.processIdentifier, name: name)   // bootstrap：啟動當下的前景
        }
        Telemetry.observe.info("軌1 視窗追蹤啟動（Accessibility \(AXIsProcessTrusted() ? "已授權" : "未授權 → 只有 app 名", privacy: .public)）")
    }

    /// 前景換 app：拆舊 observer、綁新 app、讀一次當前 window、更新 store。
    private func rebind(pid: pid_t, name: String) {
        teardown()
        observedName = name
        let axApp = AXUIElementCreateApplication(pid)
        observedApp = axApp
        AXUIElementSetMessagingTimeout(axApp, 0.5)   // app 卡住別拖垮我們
        store.observeForeground(app: name, window: focusedTitle(axApp))

        guard AXIsProcessTrusted() else { return }   // 沒權限：只給 app 名，不建 observer
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<WindowActivity>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.refresh() }
        }
        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedWindowChangedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(obs, axApp, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
    }

    /// observer callback：前景 app 內標題變了。高頻變化（terminal spinner、下載進度、影片計時）
    /// 會狂發 — debounce 1.2s，連續變化只在靜止後記一次，免洗 log + 省 AX 讀取。
    /// app 切換不走這裡（rebind 立即記），所以切 app 仍即時。
    private func refresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let axApp = self.observedApp else { return }
                self.store.observeForeground(app: self.observedName, window: self.focusedTitle(axApp))
            }
        }
    }

    /// 讀 app 的 focused window 標題（瀏覽器分頁標題跟著 window title 走）。
    private func focusedTitle(_ axApp: AXUIElement) -> String? {
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let w = win, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
              let t = title as? String, !t.isEmpty else { return nil }
        return t
    }

    private func teardown() {
        refreshTimer?.invalidate(); refreshTimer = nil
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .commonModes)
            observer = nil
        }
        observedApp = nil
    }
}
