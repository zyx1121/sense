import AppKit
import AVFoundation
import Foundation

/// 按住右 Shift 對 Sense 說話：mic → 即時轉錄 → overlay 輸入框（volatile 即時跟打，放開定格可改可送）。
/// 不持續錄音 — 按住才開 mic、放開即停；辨識引擎首次按下時暖機，之後常駐（免每次等 setUp）。
@MainActor
final class PushToTalk {
    /// 右 Shift 的 keyCode（左 = 56）。選右 ⇧：外接鍵盤也有（右 ⌥ 常缺）、不撞系統聽寫（fn）。
    private let keyCode: UInt16 = 60

    private let store: TranscriptStore
    private let locale: Locale
    private let mic = MicAudioSource()
    private var transcriber: Transcriber?
    private var pumpTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var monitors: [Any] = []

    private var prefix = ""     // 按下當下輸入框既有文字，口述接在後面
    private var finals = ""     // 本次口述累積的定稿
    private var applying = false  // 放開後留 1s 收尾段 final，之後凍結輸入框

    init(store: TranscriptStore, locale: Locale) {
        self.store = store
        self.locale = locale
    }

    func start() {
        guard monitors.isEmpty else { return }
        // flagsChanged 全域監聽吃 Accessibility 信任（shake 已申請同一權限）
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] e in
            self?.handleFlags(e)
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] e in
            self?.handleFlags(e)
            return e
        } as Any)
    }

    private func handleFlags(_ e: NSEvent) {
        guard e.keyCode == keyCode else { return }
        if e.modifierFlags.contains(.shift) { press() } else { release() }
    }

    private func press() {
        guard !store.pttRecording else { return }
        store.pttRecording = true
        store.touchOverlay()
        graceTask?.cancel(); graceTask = nil
        applying = true
        prefix = store.inputDraft
        finals = ""
        Telemetry.ptt.info("press")
        pumpTask = Task { [weak self] in
            guard let self else { return }
            do {
                if transcriber == nil {  // 首次按下暖機（model 與主 pipeline 同 locale 共用資產）
                    let t = Transcriber(locale: locale) { [weak self] r in self?.handle(r) }
                    try await t.setUp()
                    transcriber = t
                    Telemetry.ptt.info("transcriber warm [\(self.locale.identifier, privacy: .public)]")
                }
                let audio = try await mic.start()
                guard store.pttRecording else { await mic.stop(); return }  // 暖機期間已放開
                for await buffer in audio {
                    try await transcriber?.stream(buffer)
                }
            } catch {
                Telemetry.ptt.error("ptt failed: \(error.localizedDescription, privacy: .public)")
                store.appendError("語音輸入失敗：\(error.localizedDescription)")
                store.pttRecording = false
            }
        }
    }

    private func release() {
        guard store.pttRecording else { return }
        store.pttRecording = false
        store.pttTailUntil = Date().addingTimeInterval(1.5)  // 會議模式據此繼續閃避遲到的 PTT final
        Telemetry.ptt.info("release")
        Task { [weak self] in
            guard let self else { return }
            await mic.stop()           // stream finish → pump 的 for-await 自然結束
            await feedSilence(0.8)     // 餵靜音逼出尾段 final，也讓下次按下從新 segment 開始
        }
        // 放開後 1s 內仍套用遲到的 final（finalize 是非同步的），之後凍結
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            applying = false
        }
    }

    /// volatile 即時跟打；final 累積。glue 規則與逐字稿一致（ASCII 補空格、CJK 直連）。
    private func handle(_ r: ASRResult) {
        guard applying else { return }
        if r.isFinal {
            finals = glue(finals, r.text)
            store.inputDraft = glue(prefix, finals)
        } else {
            store.inputDraft = glue(glue(prefix, finals), r.text)
        }
    }

    /// 零值音訊 — SpeechTranscriber 靠靜音判定句尾，audio stream 戛然而止尾段會卡在 volatile。
    private func feedSilence(_ seconds: Double) async {
        guard let t = transcriber,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1600) else { return }
        buf.frameLength = 1600  // 0.1s
        if let p = buf.floatChannelData {
            for ch in 0..<Int(fmt.channelCount) { memset(p[ch], 0, 1600 * MemoryLayout<Float>.size) }
        }
        for _ in 0..<Int(seconds * 10) {
            try? await t.stream(PCMBuffer(pcm: buf))
        }
    }
}
