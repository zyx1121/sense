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

/// polish / translate 用的 OpenAI 模型 — 預設 gpt-5.4-nano（實測同 talk 比 mini 省 ~72%、
/// 品質沒明顯退步）；`--polish-model gpt-5.4-mini` 可換回。codex 問答另用 gpt-5.4（複雜任務）。
let polishModel: String = {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--polish-model"), args.indices.contains(i + 1) {
        return args[i + 1]
    }
    return "gpt-5.4-nano"
}()

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
    private var transcribers: [Transcriber] = []
    private var router: LanguageRouter?
    private var panel: NotchPanel?
    private var summaryWindow: SummaryWindow?
    private var agentController: AgentController?
    private var shakeCapture: ShakeCapture?
    private var statusBar: StatusBarController?
    private var pushToTalk: PushToTalk?
    private var meetingMode: MeetingMode?

    func applicationDidFinishLaunching(_: Notification) {
        Task.detached { _ = CodexAgent.shellPath }  // 背景預熱 codex PATH 解析（GUI app 貧瘠環境用）
        statusBar = StatusBarController(metrics: metrics)  // 選單列入口（控制 app 的唯一處）
        showOverlay()
        showSummaryWindow()
        startShakeCapture()
        startPipeline()
        startPushToTalk()
        setUpMeetingMode()
    }

    /// 會議模式：選單列開關 → mic 持續錄（我這側），與系統音訊雙流分轉。
    private func setUpMeetingMode() {
        guard let controller = agentController else { return }
        let meeting = MeetingMode(store: transcript, controller: controller,
                                  locale: Locale(identifier: parsedLangs()[0]))
        meetingMode = meeting
        statusBar?.onMeetingToggle = { [weak self] in
            self?.meetingMode?.toggle() ?? false
        }
        if CommandLine.arguments.contains("--meeting") {  // 啟動即開會：open … --args --meeting
            statusBar?.syncMeetingState(meeting.toggle())
        }
    }

    /// 按住右 ⇧ 對 Kilo 說話 — 口述語言取 --langs 第一個（你自己講話的主語言）。
    private func startPushToTalk() {
        let ptt = PushToTalk(store: transcript, locale: Locale(identifier: parsedLangs()[0]))
        ptt.start()
        pushToTalk = ptt
    }

    /// 辨識語言：--langs zh-TW,en-US（雙路擇優，預設）；--lang en-US（單語，向後相容）。
    private func parsedLangs() -> [String] {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        return (value(after: "--langs") ?? value(after: "--lang") ?? "zh-TW,en-US")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
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
        let polisher = TranscriptPolisher(store: transcript, archiver: TranscriptArchiver(), metrics: metrics)
        logErr("逐字稿整理模型：\(polisher.backendName)")
        let controller = AgentController(store: transcript, agent: agent, metrics: metrics,
                                         polisher: polisher,
                                         isMeeting: { [weak self] in self?.meetingMode?.isOn == true })
        self.agentController = controller
        let win = SummaryWindow(store: transcript, controller: controller)
        win.show()
        summaryWindow = win

        // 狀態欄的 overlay 控制（縮放 / 清除對話）— 跟 panel 快捷鍵、輸入框 /clear 同一套出口
        statusBar?.onZoom = { [weak self] delta in
            guard let store = self?.transcript else { return }
            if let delta { store.zoom(delta) } else { store.zoomReset() }
        }
        statusBar?.onClearConversation = { [weak self] in
            self?.agentController?.clearConversation()
        }
    }

    private func startPipeline() {
        if Keychain.openAIKey() == nil {
            logErr("⚠️ 沒有 OpenAI key（OPENAI_API_KEY 或 Keychain service=kilo account=openai）— Kilo agent 停用，字幕 + 逐字稿照常")
        }
        guard let controller = agentController else { return }

        let langs = parsedLangs()
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
