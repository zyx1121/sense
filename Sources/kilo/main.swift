import AppKit
import Foundation
import Speech
import SwiftUI

// --locales 探測語言支援（免權限）
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

// 系統音訊 → SpeechAnalyzer(zh-TW) → 瀏海字幕 + gpt-5.4-mini 摘要（可拖動 window）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captions = CaptionModel()
    private let store = SummaryStore()
    private let source = SystemAudioSource()
    private var transcriber: Transcriber?
    private var panel: NotchPanel?
    private var summaryWindow: SummaryWindow?
    private var summarizer: Summarizer?

    func applicationDidFinishLaunching(_: Notification) {
        showOverlay()
        showSummaryWindow()
        startPipeline()
    }

    private func showOverlay() {
        guard let screen = NSScreen.main else { return }
        let notchHeight = screen.notchFrame?.height ?? 38
        let width = max(screen.notchFrame?.width ?? 0, 360)
        let height = notchHeight + 40
        let rect = NSRect(x: screen.frame.midX - width / 2,
                          y: screen.frame.maxY - height,
                          width: width, height: height)
        let panel = NotchPanel(contentRect: rect)
        let hosting = NSHostingView(rootView: NotchCaptionView(model: captions))
        hosting.frame = NSRect(origin: .zero, size: rect.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func showSummaryWindow() {
        let win = SummaryWindow(store: store)
        win.show()
        summaryWindow = win
    }

    private func startPipeline() {
        let client = Keychain.openAIKey().map { OpenAIClient(apiKey: $0) }
        if client == nil {
            logErr("⚠️ 沒有 OpenAI key（設 OPENAI_API_KEY 或 Keychain service=kilo account=openai）— summary 停用，字幕照常")
        }
        let summarizer = Summarizer(store: store, client: client)
        self.summarizer = summarizer

        let transcriber = Transcriber(locale: Locale(identifier: "zh-TW"), captions: captions,
                                      onFinal: { summarizer.feed($0) })
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
