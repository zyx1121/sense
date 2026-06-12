import AppKit
import ServiceManagement
import SwiftUI

/// app 的品牌 mark（zyx logo），跟 app icon 同一個形狀 — 取代 SF Symbol sparkle。
/// vector PDF（rsvg-convert 從 zyx.svg 出，剝掉 drop-shadow、緊 bbox）：
/// rep 在繪製尺寸 rasterize，12pt 小圖不再鋸齒 — 512px PNG 走 bitmap 縮放路徑會糊。
/// template NSImage：狀態欄自動明暗、SwiftUI 端用 foregroundStyle 染色。
enum Brand {
    static let mark: NSImage = {
        if let p = Bundle.main.path(forResource: "KiloMark", ofType: "pdf"),
           let img = NSImage(contentsOfFile: p) {
            img.isTemplate = true
            return img
        }
        let fallback = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Kilo") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }()
}

/// feed / 輸入框用的品牌 mark，可 .foregroundStyle 染色、保持比例。
struct KiloMark: View {
    var size: CGFloat
    var body: some View {
        Image(nsImage: Brand.mark)
            .resizable()
            .interpolation(.high)
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// 選單列入口 — LSUIElement app 沒有 Dock 圖示，這是唯一能控制 app 的地方
/// （在這之前要關只能 pkill）。sparkle 呼應 app 內視覺語言。
@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    /// 會議模式開關（main.swift 接 MeetingMode.toggle）；回傳切換後狀態給 checkmark。
    var onMeetingToggle: (() -> Bool)?
    private var meetingOn = false

    /// overlay 縮放（main.swift 接 TranscriptStore.zoom）；delta 為 nil = 重設。
    /// 快捷鍵實際由 KeyablePanel.performKeyEquivalent 處理（overlay 是 key window 時），
    /// 選單項目標 ⌘= / ⌘- / ⌘0 當功能欄入口與提示。
    var onZoom: ((CGFloat?) -> Void)?
    /// 清除 Kilo 對話（main.swift 接 AgentController.clearConversation；輸入框打 /clear 同效）。
    var onClearConversation: (() -> Void)?

    override init() {
        super.init()
        let mark = Brand.mark.copy() as! NSImage
        mark.size = NSSize(width: 18, height: 18 * mark.size.height / mark.size.width)  // 狀態欄高度
        mark.isTemplate = true  // 跟著選單列明暗
        item.button?.image = mark
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Kilo", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let meeting = add(menu, "會議模式（錄下我的發言）", #selector(toggleMeeting), key: "m")
        meeting.state = meetingOn ? .on : .off

        add(menu, "開啟逐字稿資料夾", #selector(openTranscripts))

        menu.addItem(.separator())
        add(menu, "放大視窗", #selector(zoomIn), key: "=")
        add(menu, "縮小視窗", #selector(zoomOut), key: "-")
        add(menu, "重設視窗大小", #selector(zoomReset), key: "0")
        add(menu, "清除對話與逐字稿（開新 session）", #selector(clearConversation))
        menu.addItem(.separator())

        let perm = NSMenuItem(title: "權限設定", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        add(sub, "輔助使用…", #selector(openAccessibility))
        add(sub, "螢幕錄製…", #selector(openScreenRecording))
        add(sub, "麥克風…", #selector(openMicrophone))
        perm.submenu = sub
        menu.addItem(perm)

        let launch = add(menu, "開機時啟動", #selector(toggleLaunchAtLogin))
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        add(menu, "重新啟動 Kilo", #selector(restart))
        add(menu, "結束 Kilo", #selector(quit), key: "q")
        item.menu = menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
        return i
    }

    @objc private func openTranscripts() {
        let dir = kiloWorkdir + "/transcripts"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openScreenRecording() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openMicrophone() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func zoomIn() { onZoom?(0.1) }
    @objc private func zoomOut() { onZoom?(-0.1) }
    @objc private func zoomReset() { onZoom?(nil) }
    @objc private func clearConversation() { onClearConversation?() }

    @objc private func toggleMeeting() {
        meetingOn = onMeetingToggle?() ?? false
        rebuildMenu()
    }

    /// 外部（--meeting 啟動旗標）把開關狀態同步進選單 checkmark。
    func syncMeetingState(_ on: Bool) {
        meetingOn = on
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            logErr("開機自啟切換失敗（app 需在 /Applications，見 make install）：\(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func restart() {
        let path = Bundle.main.bundlePath
        // 延遲開新實例，等自己退出（避免兩實例搶 SCStream）
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open -n '\(path)'"]
        do { try p.run() } catch { logErr("restart 失敗：\(error.localizedDescription)") }
        NSApp.terminate(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
