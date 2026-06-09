import Foundation

/// 即時可觀測指標。footer 顯示。
@MainActor @Observable
final class MetricsStore {
    private(set) var segments = 0       // 逐字稿段數
    private(set) var asrChars = 0       // 累積辨識字數
    private(set) var codexCalls = 0
    private(set) var codexErrors = 0
    private(set) var lastCodexLatency: TimeInterval = 0  // 最近一次 codex 往返秒數

    func recordSegment(chars: Int) {
        segments += 1
        asrChars += chars
    }

    func recordCodex(latency: TimeInterval, failed: Bool) {
        codexCalls += 1
        if failed { codexErrors += 1 }
        lastCodexLatency = latency
    }
}
