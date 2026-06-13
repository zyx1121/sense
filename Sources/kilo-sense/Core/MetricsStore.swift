import Foundation

/// 即時可觀測指標。footer 顯示。
@MainActor @Observable
final class MetricsStore {
    private(set) var segments = 0       // 逐字稿段數
    private(set) var asrChars = 0       // 累積辨識字數
    private(set) var codexCalls = 0
    private(set) var codexErrors = 0
    private(set) var lastCodexLatency: TimeInterval = 0  // 最近一次 codex 往返秒數

    // LLM token 用量（polisher + codex agent，皆 gpt-5.4-mini）。token 由 API 回應的
    // usage 精確給；cost 無 API 欄位，自己用單價算。cached input 另計（便宜 10 倍）。
    private(set) var promptTokens = 0       // 含 cached
    private(set) var cachedTokens = 0       // prompt 中命中快取的部分
    private(set) var completionTokens = 0
    var totalTokens: Int { promptTokens + completionTokens }

    // 處理過的音訊總時長（秒）— 算「每 10 分鐘花費」的分母。
    private(set) var audioSeconds: Double = 0

    // gpt-5.4-mini 官方單價（USD / 1M tokens），2026-06 查 developers.openai.com：
    // input $0.75、cached input $0.075、output $4.50。
    private let inputCostPer1M = 0.75
    private let cachedInputCostPer1M = 0.075
    private let outputCostPer1M = 4.50
    var inputCostUSD: Double { Double(promptTokens - cachedTokens) / 1_000_000 * inputCostPer1M }
    var cachedCostUSD: Double { Double(cachedTokens) / 1_000_000 * cachedInputCostPer1M }
    var outputCostUSD: Double { Double(completionTokens) / 1_000_000 * outputCostPer1M }
    var estimatedCostUSD: Double { inputCostUSD + cachedCostUSD + outputCostUSD }

    /// 單位成本：每 10 分鐘音訊的花費（音訊還沒累積到 → nil）。
    var costPer10MinUSD: Double? {
        guard audioSeconds >= 1 else { return nil }
        return estimatedCostUSD / audioSeconds * 600
    }

    /// 給老闆看的用量報告（Markdown）。重點是「每 10 分鐘花費」的單位成本。
    func reportMarkdown(generatedAt: Date) -> String {
        func m(_ n: Int) -> String { String(format: "%.2fM", Double(n) / 1_000_000) }
        func usd(_ d: Double) -> String { String(format: "$%.4f", d) }
        let mins = String(format: "%.1f", audioSeconds / 60)
        let per10 = costPer10MinUSD.map { String(format: "$%.4f", $0) } ?? "—（尚無音訊）"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        return """
            # Kilo 用量報告

            - 處理音訊：**\(mins) 分鐘**
            - 單位成本：**每 10 分鐘內容 ≈ \(per10)**

            | 項目 | Tokens | 花費 |
            |---|---|---|
            | 輸入 | \(m(promptTokens - cachedTokens)) | \(usd(inputCostUSD)) |
            | 輸入（快取） | \(m(cachedTokens)) | \(usd(cachedCostUSD)) |
            | 輸出 | \(m(completionTokens)) | \(usd(outputCostUSD)) |
            | **總計** | **\(m(totalTokens))** | **\(usd(estimatedCostUSD))** |

            > 費率（gpt-5.4-mini）：輸入 $0.75 / 快取 $0.075 / 輸出 $4.50 每百萬 tokens
            > 產生：\(df.string(from: generatedAt)) · 本 session（重啟歸零）

            """
    }

    func recordSegment(chars: Int) {
        segments += 1
        asrChars += chars
    }

    /// ASR 處理的音訊時長（每段 final 的時間範圍）。
    func recordAudio(seconds: Double) {
        guard seconds > 0 else { return }
        audioSeconds += seconds
    }

    func recordCodex(latency: TimeInterval, failed: Bool) {
        codexCalls += 1
        if failed { codexErrors += 1 }
        lastCodexLatency = latency
    }

    /// API 回應 usage → 累積 token（缺值當 0）。cached ⊆ prompt。
    func recordLLMUsage(prompt: Int, cached: Int = 0, completion: Int) {
        promptTokens += prompt
        cachedTokens += cached
        completionTokens += completion
    }
}
