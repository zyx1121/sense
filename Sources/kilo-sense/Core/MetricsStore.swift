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
    // usage 精確給；cost 無 API 欄位，自己用單價算。
    private(set) var promptTokens = 0
    private(set) var completionTokens = 0
    var totalTokens: Int { promptTokens + completionTokens }

    // gpt-5.4-mini 估算單價（USD / 1M tokens）— TODO(loki): 依 OpenAI 官方定價校正。
    private let inputCostPer1M = 0.15
    private let outputCostPer1M = 0.60
    var estimatedCostUSD: Double {
        Double(promptTokens) / 1_000_000 * inputCostPer1M
            + Double(completionTokens) / 1_000_000 * outputCostPer1M
    }

    func recordSegment(chars: Int) {
        segments += 1
        asrChars += chars
    }

    func recordCodex(latency: TimeInterval, failed: Bool) {
        codexCalls += 1
        if failed { codexErrors += 1 }
        lastCodexLatency = latency
    }

    /// API 回應 usage 物件 → 累積 token（prompt/completion 缺值當 0）。
    func recordLLMUsage(prompt: Int, completion: Int) {
        promptTokens += prompt
        completionTokens += completion
    }
}
