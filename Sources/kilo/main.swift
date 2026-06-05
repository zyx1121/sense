import AppKit
import Foundation
import Speech
import SwiftUI

// M1a：--locales 探測語言支援（保留，免權限）
func dumpLocales() async {
    let supported = Array(await SpeechTranscriber.supportedLocales)
    let installed = Array(await SpeechTranscriber.installedLocales)
    func dump(_ title: String, _ ls: [Locale]) {
        print("=== \(title) (\(ls.count)) ===")
        for id in ls.map({ $0.identifier }).sorted() { print("  \(id)") }
    }
    dump("supportedLocales", supported)
    dump("installedLocales", installed)
}

func logErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

if CommandLine.arguments.contains("--locales") {
    await dumpLocales()
    exit(0)
}

// M2：系統音訊 → SpeechAnalyzer(zh-TW) → 瀏海 overlay 字幕（volatile 灰 / final 白）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captions = CaptionModel()
    private let source = SystemAudioSource()
    private var transcriber: Transcriber?
    private var panel: NotchPanel?

    func applicationDidFinishLaunching(_: Notification) {
        showOverlay()
        startPipeline()
    }

    private func showOverlay() {
        guard let screen = NSScreen.main else { return }
        let notchHeight = screen.notchFrame?.height ?? 38
        let width = max(screen.notchFrame?.width ?? 0, 360)
        // panel 頂貼螢幕頂（含被瀏海蓋的部分）+ 瀏海下方留 40pt 字幕區
        let height = notchHeight + 40
        let rect = NSRect(x: screen.frame.midX - width / 2,
                          y: screen.frame.maxY - height,
                          width: width, height: height)
        let panel = NotchPanel(contentRect: rect)
        let hosting = NSHostingView(rootView: NotchCaptionView(model: captions))
        hosting.frame = NSRect(origin: .zero, size: rect.size)
        hosting.autoresizingMask = [.width, .height]  // 撐滿 panel，否則 SwiftUI alignment 失效
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func startPipeline() {
        let transcriber = Transcriber(locale: Locale(identifier: "zh-TW"), captions: captions)
        self.transcriber = transcriber
        Task {
            do {
                try await transcriber.setUp()
                let audio = try await source.start()
                logErr("就緒，聽取中…")
                for await buffer in audio { try await transcriber.stream(buffer) }
            } catch {
                logErr("error: \(error)")
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // 無 Dock 圖示的背景 app
app.run()
