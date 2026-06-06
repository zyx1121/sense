import AppKit
import SwiftUI

/// 可拖動的 summary / insight overlay 視窗：borderless、拖背景移動、floating。
/// 高度動態：內容由 SwiftUI 決定，NSHostingController 的 preferredContentSize 驅動 panel 大小。
@MainActor
final class SummaryWindow {
    private let panel: NSPanel

    init(store: SummaryStore, metrics: MetricsStore) {
        let hosting = NSHostingController(rootView: SummaryView(store: store, metrics: metrics))
        hosting.sizingOptions = [.preferredContentSize]   // SwiftUI 內容高度 → 自動 resize panel

        panel = NSPanel(
            contentRect: NSRect(x: 80, y: 420, width: 320, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true            // 拖任意處移動
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = hosting
    }

    func show() { panel.orderFrontRegardless() }
}

struct SummaryView: View {
    let store: SummaryStore
    let metrics: MetricsStore

    private var recent: [Insight] { Array(store.insights.suffix(3).reversed()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Kilo")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            if recent.isEmpty {
                Text("讀取中…")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 16).padding(.bottom, 8)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recent) { insight in
                        Text(insight.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
            }

            Divider().overlay(.white.opacity(0.1))
            MetricFooter(metrics: metrics)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)   // 高度貼合內容（驅動動態高度）
        .glassEffect(in: .rect(cornerRadius: 16))  // macOS 26 Liquid Glass（.nonactivating panel 失焦會降級成模糊，見 PR note）
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: recent.count)  // 擴展/收合動畫
    }
}

private struct MetricFooter: View {
    let metrics: MetricsStore

    var body: some View {
        HStack(spacing: 14) {
            stat("段", "\(metrics.segments)")
            stat("tok", "\(metrics.tokensIn)/\(metrics.tokensOut)")
            stat("$", String(format: "%.4f", metrics.costUSD))
            stat("延遲", String(format: "%.1fs", metrics.lastLatency))
            if metrics.summaryErrors > 0 {
                stat("err", "\(metrics.summaryErrors)", color: .red.opacity(0.85))
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func stat(_ label: String, _ value: String, color: Color = .white.opacity(0.8)) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(color)
            Text(label).font(.system(size: 8)).foregroundStyle(.white.opacity(0.4))
        }
    }
}
