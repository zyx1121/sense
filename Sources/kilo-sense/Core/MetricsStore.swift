import Foundation

/// 即時可觀測指標 + 跨 session 持久化的 LLM 用量帳。
/// 本 session（app 開機後歸零）給「單部影片成本」對比；累計（~/.kilo/usage-state.json）
/// 跨重啟不丟，給老闆看總帳。report 每次用量變動 debounce 寫 ~/.kilo/usage-report.md，
/// 隨時是最新（不靠選單 osascript 觸發）。
@MainActor @Observable
final class MetricsStore {
    private(set) var segments = 0       // 逐字稿段數
    private(set) var asrChars = 0       // 累積辨識字數
    private(set) var codexCalls = 0
    private(set) var codexErrors = 0
    private(set) var lastCodexLatency: TimeInterval = 0  // 最近一次 codex 往返秒數

    // 本 session token 用量（含 cached ⊆ prompt）
    private(set) var promptTokens = 0
    private(set) var cachedTokens = 0
    private(set) var completionTokens = 0
    var totalTokens: Int { promptTokens + completionTokens }
    private(set) var audioSeconds: Double = 0  // 處理過的音訊秒數（每 10 分鐘成本的分母）

    // 跨 session 累計（持久化）。cost 累加而非重算 — 跨模型（mini/nano）各筆用當時費率才準。
    private(set) var lifetimePrompt = 0
    private(set) var lifetimeCompletion = 0
    private(set) var lifetimeAudio: Double = 0
    private(set) var lifetimeCostUSD: Double = 0

    /// model → (input, cached, output) USD per 1M tokens。官方定價（developers.openai.com, 2026-06）。
    static let rates: [String: (input: Double, cached: Double, output: Double)] = [
        "gpt-5.4-mini": (0.75, 0.075, 4.50),
        "gpt-5.4-nano": (0.20, 0.02, 1.25),
    ]
    /// 當前 polish 模型費率（未知 model fallback mini）。
    private var rate: (input: Double, cached: Double, output: Double) {
        Self.rates[polishModel] ?? (0.75, 0.075, 4.50)
    }

    private let stateURL = URL(fileURLWithPath: kiloWorkdir + "/usage-state.json")
    private let reportURL = URL(fileURLWithPath: kiloWorkdir + "/usage-report.md")
    private var writeTask: Task<Void, Never>?

    init() { loadLifetime() }

    /// 給定 token 數的花費（當前 model 費率）。
    func cost(prompt: Int, cached: Int, completion: Int) -> Double {
        Double(prompt - cached) / 1_000_000 * rate.input
            + Double(cached) / 1_000_000 * rate.cached
            + Double(completion) / 1_000_000 * rate.output
    }
    var sessionCostUSD: Double { cost(prompt: promptTokens, cached: cachedTokens, completion: completionTokens) }
    /// 單位成本：每 10 分鐘音訊的花費（本 session；音訊未累積 → nil）。
    var costPer10MinUSD: Double? {
        guard audioSeconds >= 1 else { return nil }
        return sessionCostUSD / audioSeconds * 600
    }

    func recordSegment(chars: Int) {
        segments += 1
        asrChars += chars
    }

    func recordAudio(seconds: Double) {
        guard seconds > 0 else { return }
        audioSeconds += seconds
        lifetimeAudio += seconds
        scheduleWrite()
    }

    func recordCodex(latency: TimeInterval, failed: Bool) {
        codexCalls += 1
        if failed { codexErrors += 1 }
        lastCodexLatency = latency
    }

    /// API 回應 usage → 累積 token + 用當下費率累加 cost（cached ⊆ prompt）。
    func recordLLMUsage(prompt: Int, cached: Int = 0, completion: Int) {
        promptTokens += prompt
        cachedTokens += cached
        completionTokens += completion
        lifetimePrompt += prompt
        lifetimeCompletion += completion
        lifetimeCostUSD += cost(prompt: prompt, cached: cached, completion: completion)
        scheduleWrite()
    }

    // MARK: - 持久化

    private func loadLifetime() {
        guard let data = try? Data(contentsOf: stateURL),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lifetimePrompt = j["prompt"] as? Int ?? 0
        lifetimeCompletion = j["completion"] as? Int ?? 0
        lifetimeAudio = j["audioSeconds"] as? Double ?? 0
        lifetimeCostUSD = j["costUSD"] as? Double ?? 0
    }

    /// record 高頻 — debounce 2s 才落地，不每筆寫檔。
    private func scheduleWrite() {
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            persist()
        }
    }

    private func persist() {
        let state: [String: Any] = [
            "prompt": lifetimePrompt, "completion": lifetimeCompletion,
            "audioSeconds": lifetimeAudio, "costUSD": lifetimeCostUSD,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: stateURL)
        }
        try? reportMarkdown(generatedAt: Date()).write(to: reportURL, atomically: true, encoding: .utf8)
    }

    // MARK: - 報表

    /// 給老闆看的用量報告（Markdown）。本 session = 單部影片成本對比；累計 = 跨 session 總帳。
    func reportMarkdown(generatedAt: Date) -> String {
        func m(_ n: Int) -> String { String(format: "%.2fM", Double(n) / 1_000_000) }
        func usd(_ d: Double) -> String { String(format: "$%.4f", d) }
        let r = rate
        let mins = String(format: "%.1f", audioSeconds / 60)
        let per10 = costPer10MinUSD.map { usd($0) } ?? "—（尚無音訊）"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return """
            # Kilo 用量報告

            ## 本 session（app 開機後 · model: \(polishModel)）
            - 處理音訊：**\(mins) 分鐘**
            - 單位成本：**每 10 分鐘內容 ≈ \(per10)**

            | 項目 | Tokens | 花費 |
            |---|---|---|
            | 輸入 | \(m(promptTokens - cachedTokens)) | \(usd(Double(promptTokens - cachedTokens) / 1_000_000 * r.input)) |
            | 輸入（快取） | \(m(cachedTokens)) | \(usd(Double(cachedTokens) / 1_000_000 * r.cached)) |
            | 輸出 | \(m(completionTokens)) | \(usd(Double(completionTokens) / 1_000_000 * r.output)) |
            | **總計** | **\(m(totalTokens))** | **\(usd(sessionCostUSD))** |

            ## 累計（跨 session 總帳）
            - 處理音訊：\(String(format: "%.1f", lifetimeAudio / 60)) 分鐘
            - 總 tokens：\(m(lifetimePrompt + lifetimeCompletion))
            - 總花費：**\(usd(lifetimeCostUSD))**（各筆按當時模型費率累加）

            > 費率（\(polishModel)）：輸入 $\(r.input) / 快取 $\(r.cached) / 輸出 $\(r.output) 每百萬 tokens
            > 產生：\(df.string(from: generatedAt))

            """
    }
}
