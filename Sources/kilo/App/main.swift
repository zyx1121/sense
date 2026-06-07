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

/// codex agent 的 workspace；reply 裡的相對路徑連結也解析到這底下。
let kiloWorkdir = NSHomeDirectory() + "/.kilo"

if CommandLine.arguments.contains("--locales") {
    await dumpLocales()
    exit(0)
}

// 系統音訊 → 瀏海字幕 + 連續逐字稿（小模型即時整理）；shake 圈選畫面 + codex agent 分析
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captions = CaptionModel()
    private let transcript = TranscriptStore()
    private let metrics = MetricsStore()
    private let source = SystemAudioSource()
    private let micSource = MicAudioSource()
    private var transcribers: [Transcriber] = []
    private var micTranscriber: Transcriber?
    private var router: LanguageRouter?
    private var panel: NotchPanel?
    private var summaryWindow: SummaryWindow?
    private var agentController: AgentController?
    private var shakeCapture: ShakeCapture?

    func applicationDidFinishLaunching(_: Notification) {
        showOverlay()
        showSummaryWindow()
        startShakeCapture()
        startPipeline()
        startMicCommands()
    }

    /// 麥克風 → 語音指令（「kilo …」）。指令只能從使用者的嘴來 —
    /// 系統音訊路沒有指令權，影片/直播喊 kilo 都不算數。
    /// 預設關（很多場景不能講話 + mic 常駐有錄音指示點），`--voice` 開啟。
    private func startMicCommands() {
        guard CommandLine.arguments.contains("--voice") else {
            logErr("語音指令未啟用（--voice 開啟）")
            return
        }
        guard let controller = agentController else { return }
        let wake = VoiceWake()
        let captions = self.captions
        let transcriber = Transcriber(
            locale: Locale(identifier: "zh-TW"),
            contextualStrings: ["kilo", "Kilo"]) { result in
            guard result.isFinal else { return }
            Telemetry.asr.info("mic final: \(String(result.text.prefix(40)), privacy: .public)")
            switch wake.process(result.text) {
            case .armed:
                Telemetry.asr.info("wake armed — listening for command")
                captions.setVolatile("在聽，請說指令…")   // 瀏海給個回饋
            case .command(let cmd):
                guard !controller.isThinking else { return }
                Telemetry.asr.info("voice command: \(cmd, privacy: .public)")
                captions.commitFinal("→ \(cmd)")
                controller.submit(cmd)
            case nil:
                break
            }
        }
        self.micTranscriber = transcriber
        let source = micSource
        Task {
            guard await MicAudioSource.requestPermission() else {
                logErr("⚠️ 麥克風權限未授予 — 語音指令停用（逐字稿照常）")
                return
            }
            do {
                try await transcriber.setUp()
                let audio = try await source.start()
                logErr("語音指令就緒（對麥克風說「kilo …」）")
                for await buffer in audio { try await transcriber.stream(buffer) }
            } catch {
                logErr("mic pipeline error: \(error)")
            }
        }
    }

    /// 晃游標 → 圈選畫面元素給 Kilo 看（dim + spotlight + click capture）。
    private func startShakeCapture() {
        let shake = ShakeCapture(store: transcript)
        shake.onSelectingChange = { [weak self] on in
            self?.summaryWindow?.setElevated(on)
        }
        shake.passThroughFrame = { [weak self] in
            self?.summaryWindow?.cgFrame ?? .zero
        }
        shake.start()
        shakeCapture = shake
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
            CodexAgent(workdir: kiloWorkdir, apiKey: $0)
        }
        let polisher = TranscriptPolisher(store: transcript, archiver: TranscriptArchiver())
        logErr("逐字稿整理模型：\(polisher.backendName)")
        let controller = AgentController(store: transcript, agent: agent, metrics: metrics, polisher: polisher)
        self.agentController = controller
        let win = SummaryWindow(store: transcript, controller: controller)
        win.show()
        summaryWindow = win
    }

    private func startPipeline() {
        if Keychain.openAIKey() == nil {
            logErr("⚠️ 沒有 OpenAI key（OPENAI_API_KEY 或 Keychain service=kilo account=openai）— Kilo agent 停用，字幕 + 逐字稿照常")
        }
        guard let controller = agentController else { return }

        // 辨識語言：--langs zh-TW,en-US（雙路擇優，預設）；--lang en-US（單語，向後相容）
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let langs = (value(after: "--langs") ?? value(after: "--lang") ?? "zh-TW,en-US")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        logErr("辨識語言：\(langs.joined(separator: " + "))\(langs.count > 1 ? "（信心擇優）" : "")")

        let router = LanguageRouter(initial: langs[0], captions: captions, controller: controller)
        self.router = router
        let transcribers = langs.map { lang in
            Transcriber(locale: Locale(identifier: lang)) { result in
                router.handle(result)
            }
        }
        self.transcribers = transcribers
        Task {
            do {
                for t in transcribers { try await t.setUp() }
                let audio = try await startAudioWithRetry()
                logErr("就緒，聽取中…")
                for await buffer in audio {
                    for t in transcribers { try await t.stream(buffer) }
                }
            } catch {
                logErr("error: \(error)")
            }
        }
    }

    /// SCK audio 啟動偶發 -3818（上個 capture session 還在收尾、開機競態）— 遞增退避重試。
    private func startAudioWithRetry(attempts: Int = 5) async throws -> AsyncStream<PCMBuffer> {
        var lastError: Error?
        for i in 1...attempts {
            do {
                return try await source.start()
            } catch {
                lastError = error
                logErr("audio start 失敗（\(i)/\(attempts)），\(i * 2)s 後重試：\(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(Double(i) * 2))
            }
        }
        throw lastError ?? SystemAudioError.noDisplay
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // 無 Dock 圖示的背景 app
app.run()
