import AppKit
import SwiftUI

/// borderless panel 必須 override canBecomeKey，input TextField 才拿得到焦點打字。
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 可拖動的 Kilo overlay：分段逐字稿 + 指令輸入 + Kilo 回應。floating、拖背景移動、高度動態。
@MainActor
final class SummaryWindow {
    private let panel: KeyablePanel

    init(store: TranscriptStore, metrics: MetricsStore, controller: AgentController) {
        let hosting = NSHostingController(
            rootView: TranscriptView(store: store, metrics: metrics, controller: controller))
        hosting.sizingOptions = [.preferredContentSize]

        panel = KeyablePanel(
            contentRect: NSRect(x: 80, y: 360, width: 360, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = hosting
    }

    func show() { panel.orderFrontRegardless() }
}

struct TranscriptView: View {
    let store: TranscriptStore
    let metrics: MetricsStore
    let controller: AgentController
    @State private var input = ""

    private var recent: [String] { Array(store.segments.suffix(8)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Kilo")
                .font(.headline).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            // 分段逐字稿
            if recent.isEmpty {
                Text("聽取中…")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 16).padding(.bottom, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(recent.enumerated()), id: \.offset) { i, seg in
                                Text(seg)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(.white.opacity(0.05), in: .rect(cornerRadius: 8))
                                    .id(i)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .frame(height: 220)
                    .onChange(of: recent.count) { _, c in
                        withAnimation { proxy.scrollTo(c - 1, anchor: .bottom) }
                    }
                }
            }

            // Kilo 回應
            if let reply = store.reply {
                Text(reply)
                    .font(.system(size: 12)).foregroundStyle(.cyan.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }

            // 指令輸入 → codex agent
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                TextField("問 Kilo，或叫它記錄…", text: $input)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(.white)
                    .onSubmit { controller.submit(input); input = "" }
                if store.thinking { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.white.opacity(0.06))

            Divider().overlay(.white.opacity(0.1))
            MetricFooter(metrics: metrics)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(in: .rect(cornerRadius: 16))
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: recent.isEmpty)
    }
}

private struct MetricFooter: View {
    let metrics: MetricsStore

    var body: some View {
        HStack(spacing: 14) {
            stat("段", "\(metrics.segments)")
            stat("字", "\(metrics.asrChars)")
            stat("codex", "\(metrics.codexCalls)")
            stat("延遲", String(format: "%.1fs", metrics.lastCodexLatency))
            if metrics.codexErrors > 0 {
                stat("err", "\(metrics.codexErrors)", color: .red.opacity(0.85))
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
