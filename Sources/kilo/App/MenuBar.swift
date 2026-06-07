import AppKit
import ServiceManagement

/// 選單列入口 — LSUIElement app 沒有 Dock 圖示，這是唯一能控制 app 的地方
/// （在這之前要關只能 pkill）。sparkle 呼應 app 內視覺語言。
@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Kilo")
        item.button?.image?.isTemplate = true  // 跟著選單列明暗
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Kilo", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        add(menu, "開啟逐字稿資料夾", #selector(openTranscripts))

        let perm = NSMenuItem(title: "權限設定", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        add(sub, "輔助使用…", #selector(openAccessibility))
        add(sub, "螢幕錄製…", #selector(openScreenRecording))
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
