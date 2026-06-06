import Foundation

struct Insight: Identifiable {
    let id = UUID()
    let text: String
}

/// summary / insight 清單，SummaryView 觀察。
@MainActor @Observable
final class SummaryStore {
    private(set) var insights: [Insight] = []

    func add(_ text: String) {
        guard !text.isEmpty else { return }
        insights.append(Insight(text: text))
    }
}
