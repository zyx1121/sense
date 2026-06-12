import Foundation

// 指令（含前文參考）全放 system / instructions，user message 只放純 raw 文字 —
// 小模型會把混在 user message 裡的 scaffold 標記與「前文參考」當內文照抄（nano 實測翻車）。
// 指令語言跟著 chunk 語言走：中文指令配英文 chunk 會被 nano「統一」成中文（實測翻譯翻車，
// transformer 被翻成《變形金剛》），英文 chunk 必須配英文指令。
private func composeInstructions(locale: String, contextTail: String) -> String {
    let base: String
    // 「一句一行」不在指令裡 — nano/mini 實測都不穩定遵守，斷行由 commitPolished 的確定性後處理做
    if locale.hasPrefix("zh") {
        base = """
            你是逐字稿整理員。使用者訊息是一段中文語音辨識的原始逐字稿，整理它：
            - 補上標點符號
            - 修正辨識錯字：同音字、形近字、語境不通的字（例如「迴到中文」應作「回到中文」），\
            依上下文還原最合理的說法；真的無法判斷才保留原字。不要改寫句構、不要潤飾
            - 輸出必須是中文（原語言），絕對不要翻譯
            - 不增刪語意、不摘要、不回答問題、不加任何說明或標記
            只輸出整理後的文字本身。
            """
    } else {
        base = """
            You clean up a raw English speech-recognition transcript. Rules:
            - Add punctuation
            - Fix mis-recognitions (homophones, garbled words) using context; \
            keep the original wording only when genuinely undecidable. Do not paraphrase
            - The output MUST be in English (the original language). NEVER translate
            - Do not add, remove, or summarize content; no comments or labels
            Output only the cleaned text itself.
            """
    }
    guard !contextTail.isEmpty else { return base }
    let ref = locale.hasPrefix("zh")
        ? "\n\n已整理的前文結尾（可能是其他語言，僅供銜接參考，它不是輸入、絕對不要輸出它）：\n"
        : "\n\nEnd of the already-cleaned text (may be another language; continuity reference only — it is NOT input, NEVER output it):\n"
    return base + ref + contextTail
}

/// 小模型即時整理逐字稿：pendingRaw 滿 60 字立刻整理、不滿則 4s idle 後整理；
/// 一次一個 in-flight，失敗就原文轉正不卡流。沒 OpenAI key → 整理關閉（raw 留在 pendingRaw）。
/// 整理走 gpt-5.4-mini 直打 API（不走 codex exec，省 22k token 的 agent prompt）。
/// 不用 on-device FoundationModels：實測錯字修正明顯較差（只修指令例子教過的、英文偏保守），
/// 且需 Apple Intelligence 啟用（Mac 與 Siri 同語言）— 純退步，移除。
@MainActor
final class TranscriptPolisher {
    private let store: TranscriptStore
    private let archiver: TranscriptArchiver
    private let apiKey: String?
    private let model = "gpt-5.4-mini"
    private var running = false
    private var idleTask: Task<Void, Never>?
    private let pairLogger = PolishPairLogger()  // 語料本金：(raw → cleaned) 配對累積

    var backendName: String { apiKey == nil ? "無（原文直出）" : model }

    init(store: TranscriptStore, archiver: TranscriptArchiver) {
        self.store = store
        self.archiver = archiver
        self.apiKey = Keychain.openAIKey()
    }

    /// 每段 final 進來後呼叫。批次 = 開頭同語言的連續段：
    /// 滿 60 字立刻整理；語言切換點（boundary）不等湊字數直接沖；其他 4s idle 後整理。
    func nudge() {
        guard apiKey != nil, !running else { return }
        guard let run = store.firstPendingRun() else { return }
        // 滿字數觸發 = 人還在講 → 批尾的未完 final 扣給下一批；換人/idle 觸發不扣
        if run.text.count >= 60 || run.boundary { kick(holdTail: !run.boundary); return }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            kick(holdTail: false)
        }
    }

    private func kick(holdTail: Bool) {
        guard apiKey != nil, !running else { return }
        guard let run = store.firstPendingRun(dropIncompleteTail: holdTail) else { return }
        running = true
        idleTask?.cancel()
        let tail = String(store.polished.suffix(120))
        let epoch = store.transcriptEpoch  // 清除畫面時這批只進歸檔、不上畫面
        Task {
            var committed: String?
            do {
                let cleaned = try await polish(chunk: run.text, locale: run.locale, contextTail: tail)
                committed = store.commitPolished(cleaned.isEmpty ? run.text : cleaned, locale: run.locale, consumedSegments: run.segments, source: run.source, isSpeaker: run.isSpeaker, epoch: epoch, timeRange: run.timeRange)
                Telemetry.polish.info("polished [\(run.locale, privacy: .public)] \(run.text.count, privacy: .public) -> \(cleaned.count, privacy: .public) chars")
                if !cleaned.isEmpty {
                    pairLogger.log(raw: run.text, cleaned: cleaned, locale: run.locale, contextTail: tail)
                }
            } catch {
                committed = store.commitPolished(run.text, locale: run.locale, consumedSegments: run.segments, source: run.source, isSpeaker: run.isSpeaker, epoch: epoch, timeRange: run.timeRange)  // 原文轉正，不卡顯示
                Telemetry.polish.error("polish failed: \(error.localizedDescription, privacy: .public)")
            }
            if let committed { archiver.append(committed, source: run.source) }  // 持久化（整理後的定稿）
            running = false
            nudge()  // 積壓續跑 / 重設 idle timer
        }
    }

    /// gpt-5.4-mini 直打 chat completions：system 放指令、user 只放 raw chunk。
    private func polish(chunk: String, locale: String, contextTail: String) async throws -> String {
        guard let apiKey else { return chunk }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": composeInstructions(locale: locale, contextTail: contextTail)],
                ["role": "user", "content": chunk],
            ],
            "max_completion_tokens": 2000,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
        else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Polish", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "polish API error: \(body.prefix(200))"])
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
