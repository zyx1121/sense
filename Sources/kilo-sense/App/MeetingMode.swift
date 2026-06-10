import Foundation

/// 會議模式：持續錄 mic（你這側的發言）進逐字稿，與系統音訊雙流分轉 —
/// 系統音訊 = 對方（來源標前景 app）、mic = 「我」。開會時系統 loopback 聽不到你自己
/// 的聲音（mic 是獨立輸入流），不開這個你的發言就不在記錄裡。
/// v1 假設戴耳機 — 外放時 mic 會收到對方聲音造成重複轉錄（回音消除留待 AVAudioEngine voice processing）。
@MainActor
final class MeetingMode {
    private let store: TranscriptStore
    private let controller: AgentController
    private let locale: Locale
    private let mic = MicAudioSource()
    private var transcriber: Transcriber?   // 首次開啟暖機，之後常駐
    private var pumpTask: Task<Void, Never>?
    private(set) var isOn = false

    /// 低於此信心的 mic 定稿當環境雜訊丟掉 — mic 對著自己，真句信心通常遠高於此。
    private let noiseFloor = 0.45

    init(store: TranscriptStore, controller: AgentController, locale: Locale) {
        self.store = store
        self.controller = controller
        self.locale = locale
    }

    /// 選單列開關入口；回傳切換後狀態（給 checkmark）。
    func toggle() -> Bool {
        if isOn { stop() } else { start() }
        return isOn
    }

    private func start() {
        isOn = true
        Telemetry.meeting.info("on")
        pumpTask = Task { [weak self] in
            guard let self else { return }
            do {
                if transcriber == nil {
                    let t = Transcriber(locale: locale) { [weak self] r in self?.handle(r) }
                    try await t.setUp()
                    transcriber = t
                    Telemetry.meeting.info("transcriber warm [\(self.locale.identifier, privacy: .public)]")
                }
                let audio = try await mic.start()
                guard isOn else { await mic.stop(); return }  // 暖機期間已關閉
                for await buffer in audio {
                    try await transcriber?.stream(buffer)
                }
            } catch {
                Telemetry.meeting.error("meeting mode failed: \(error.localizedDescription, privacy: .public)")
                store.appendError("會議模式啟動失敗：\(error.localizedDescription)")
                isOn = false
            }
        }
    }

    private func stop() {
        isOn = false
        Telemetry.meeting.info("off")
        Task { [weak self] in await self?.mic.stop() }  // stream finish → pump 自然結束
    }

    /// 只收 final 進逐字稿（mic 的 volatile 不跟系統流搶單一 volatile 顯示槽）；
    /// 來源固定「我」— archiver 換來源時自動插 header，會議記錄直接我/對方分段。
    private func handle(_ r: ASRResult) {
        guard isOn, r.isFinal else { return }
        guard (r.confidence ?? 1) >= noiseFloor else {
            Telemetry.meeting.info("final dropped (noise) conf=\(r.confidence ?? -1, format: .fixed(precision: 2), privacy: .public)")
            return
        }
        controller.appendMicFinal(r.text, locale: r.locale)
    }
}
