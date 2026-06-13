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
/// 整理直打 OpenAI API（不走 codex exec，省 22k token 的 agent prompt）。
/// 不用 on-device FoundationModels：實測錯字修正明顯較差（只修指令例子教過的、英文偏保守），
/// 且需 Apple Intelligence 啟用（Mac 與 Siri 同語言）— 純退步，移除。
@MainActor
final class TranscriptPolisher {
    private let store: TranscriptStore
    private let archiver: TranscriptArchiver
    private let metrics: MetricsStore
    private let apiKey: String?
    private let model = polishModel  // 預設 gpt-5.4-nano；--polish-model 可換
    private var running = false
    private var idleTask: Task<Void, Never>?
    private let pairLogger = PolishPairLogger()  // 語料本金：(raw → cleaned) 配對累積

    var backendName: String { apiKey == nil ? "無（原文直出）" : model }

    init(store: TranscriptStore, archiver: TranscriptArchiver, metrics: MetricsStore) {
        self.store = store
        self.archiver = archiver
        self.metrics = metrics
        self.apiKey = Keychain.openAIKey()
    }

    /// 每段 final 進來後呼叫。批次 = 開頭同語言的連續段：
    /// 滿 60 字立刻整理；語言切換點（boundary）不等湊字數直接沖；其他 4s idle 後整理。
    func nudge() {
        guard apiKey != nil, !running else { return }
        guard let run = store.firstPendingRun() else { return }
        if run.boundary { kick(holdTail: false); return }  // 換人邊界：切點已定，直接送
        if run.text.count >= 60 { kick(holdTail: true); return }  // 滿字數：扣尾段（批尾可能是半句）後送
        schedule(after: 4, holdTail: false)  // 不滿字數：idle 4s 後沖掉（人停了）
    }

    private func schedule(after seconds: Double, holdTail: Bool) {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            kick(holdTail: holdTail)
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
            var result: (text: String?, blockID: UUID?) = (nil, nil)
            do {
                let cleaned = try await polish(chunk: run.text, locale: run.locale, contextTail: tail)
                result = store.commitPolished(cleaned.isEmpty ? run.text : cleaned, locale: run.locale, consumedSegments: run.segments, source: run.source, epoch: epoch, timeRange: run.timeRange)
                Telemetry.polish.info("polished [\(run.locale, privacy: .public)] \(run.text.count, privacy: .public) -> \(cleaned.count, privacy: .public) chars")
                if !cleaned.isEmpty {
                    pairLogger.log(raw: run.text, cleaned: cleaned, locale: run.locale, contextTail: tail)
                }
            } catch {
                result = store.commitPolished(run.text, locale: run.locale, consumedSegments: run.segments, source: run.source, epoch: epoch, timeRange: run.timeRange)  // 原文轉正，不卡顯示
                Telemetry.polish.error("polish failed: \(error.localizedDescription, privacy: .public)")
            }
            if let text = result.text { archiver.append(text, source: run.source) }  // 持久化（整理後的定稿）
            // 外語段落（非中文）背景翻成中文，回填該塊 — 中文內容不翻（省 token，母語免譯）
            if let text = result.text, let id = result.blockID, !run.locale.hasPrefix("zh") {
                Task { [weak self] in
                    guard let self, let zh = try? await translate(text) else { return }
                    store.appendTranslation(blockID: id, zh)
                }
            }
            running = false
            nudge()  // 積壓續跑 / 重設 idle timer
        }
    }

    /// 外語段落 → 繁中譯文（走 polish 模型，只給譯文）。token 計入 metrics。
    private func translate(_ text: String) async throws -> String {
        guard let apiKey else { return "" }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": "把使用者訊息翻成繁體中文，只輸出譯文本身，不要任何說明、引號或標記。"],
                ["role": "user", "content": text],
            ],
            "max_completion_tokens": 2000,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
        else { return "" }
        recordUsage(json)
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 直打 chat completions：system 放指令、user 只放 raw chunk。
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
        recordUsage(json)
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// API 回應 usage → metrics（prompt 含 cached，cached 在 prompt_tokens_details）。
    private func recordUsage(_ json: [String: Any]) {
        guard let usage = json["usage"] as? [String: Any] else { return }
        let p = usage["prompt_tokens"] as? Int ?? 0
        let cached = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        let comp = usage["completion_tokens"] as? Int ?? 0
        metrics.recordLLMUsage(prompt: p, cached: cached, completion: comp)
        Telemetry.polish.info("usage prompt=\(p, privacy: .public) cached=\(cached, privacy: .public) completion=\(comp, privacy: .public)")
    }
}
