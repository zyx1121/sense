import AppKit
import SwiftUI

/// 可拖動的 summary / insight overlay 視窗：borderless、拖背景移動、floating。
@MainActor
final class SummaryWindow {
    private let panel: NSPanel

    init(store: SummaryStore) {
        panel = NSPanel(
            contentRect: NSRect(x: 80, y: 160, width: 320, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true            // 拖任意處移動
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: SummaryView(store: store))
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    func show() { panel.orderFrontRegardless() }
}

struct SummaryView: View {
    let store: SummaryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Insights")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            if store.insights.isEmpty {
                Text("聽取中…摘要會出現在這裡")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.insights.reversed()) { insight in
                            Text(insight.text)
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black.opacity(0.85), in: .rect(cornerRadius: 16))
    }
}
