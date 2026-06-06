import Foundation

/// 累積定稿逐字稿，切段後丟給 gpt-5.4-mini 摘要。
/// 切段：停頓 6 秒（沒有新定稿）或累積 ≥500 字，誰先到誰觸發。
@MainActor
final class Summarizer {
    private let store: SummaryStore
    private let client: OpenAIClient?
    private var buffer = ""
    private var flushTask: Task<Void, Never>?

    init(store: SummaryStore, client: OpenAIClient?) {
        self.store = store
        self.client = client
    }

    /// 餵入一段定稿逐字稿（只送 finalized，別送 volatile）。
    func feed(_ finalText: String) {
        buffer += finalText
        if buffer.count >= 500 { flush() } else { scheduleFlush() }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled else { return }
            flush()
        }
    }

    private func flush() {
        flushTask?.cancel()
        let segment = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard segment.count >= 10, let client else { return }  // 太短 / 沒 key 就不送
        Task { [weak self] in
            do {
                let summary = try await client.summarize(segment)
                self?.store.add(summary)
            } catch {
                FileHandle.standardError.write(
                    Data("summarize error: \(error.localizedDescription)\n".utf8))
            }
        }
    }
}
