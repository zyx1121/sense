import AppKit
import Foundation
import OSLog
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

// 系統音訊 → 瀏海字幕 + 分段逐字稿 overlay + Kilo agent（codex）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captions = CaptionModel()
    private let transcript = TranscriptStore()
    private let metrics = MetricsStore()
    private let source = SystemAudioSource()
    private var transcriber: Transcriber?
    private var panel: NotchPanel?
    private var summaryWindow: SummaryWindow?
    private var agentController: AgentController?

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
        let agent = Keychain.openAIKey().map {
            CodexAgent(workdir: NSHomeDirectory() + "/.kilo", apiKey: $0)
        }
        let controller = AgentController(store: transcript, agent: agent, metrics: metrics)
        self.agentController = controller
        let win = SummaryWindow(store: transcript, metrics: metrics, controller: controller)
        win.show()
        summaryWindow = win
    }

    private func startPipeline() {
        if Keychain.openAIKey() == nil {
            logErr("⚠️ 沒有 OpenAI key（OPENAI_API_KEY 或 Keychain service=kilo account=openai）— Kilo agent 停用，字幕 + 逐字稿照常")
        }
        let controller = agentController

        // 辨識語言：--lang en-US 等；預設 zh-TW
        let args = CommandLine.arguments
        let lang = args.firstIndex(of: "--lang").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "zh-TW"
        logErr("辨識語言：\(lang)")

        let transcriber = Transcriber(
            locale: Locale(identifier: lang), captions: captions,
            onFinal: { text in
                controller?.appendFinal(text)   // → 逐字稿分段 + metrics + codex context
                Telemetry.asr.info("final chars=\(text.count, privacy: .public)")
            })
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
