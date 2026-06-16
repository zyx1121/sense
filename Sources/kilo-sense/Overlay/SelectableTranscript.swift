import AppKit
import SwiftUI

/// 逐字稿顯示 — NSTextView 接管：可選取、關掉 macOS data detector（不再冒出對逐字稿
/// 無用的 Look Up / Translate / Open / Show in Finder 等系統項），右鍵選單完全自訂。
/// NSTextView 原生扛大量文字 + 選取 + 捲動，也解掉 SwiftUI Text 高頻重繪反壓（PR #82/#83）。
/// tick = store.transcriptLength：讓父 view 讀到它 → 內容變動觸發 updateNSView 重建。
struct SelectableTranscript: NSViewRepresentable {
    let store: TranscriptStore
    let tick: Int

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = KiloTextView(frame: .zero)
        tv.coordinator = context.coordinator
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        let stick = scroll.contentView.bounds.maxY >= tv.bounds.height - 24
        tv.textStorage?.setAttributedString(Self.attributed(store: store))
        if stick { tv.scrollToEndOfDocument(nil) }
    }

    private static func attributed(store: TranscriptStore) -> NSAttributedString {
        let scale = store.uiScale
        let para = NSMutableParagraphStyle(); para.lineSpacing = 3.5
        func white(_ s: String, _ opacity: CGFloat, _ size: CGFloat = 12) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: size * scale),
                .foregroundColor: NSColor.white.withAlphaComponent(opacity),
                .paragraphStyle: para])
        }
        let out = NSMutableAttributedString()
        for (i, block) in store.polishedBlocks.suffix(18).enumerated() {
            if i > 0 { out.append(white("\n\n", 0.92)) }
            out.append(headerLine(block, scale: scale, para: para))
            for (j, p) in block.paras.enumerated() {
                out.append(white(j == 0 ? "\n" : "\n\n", 0.92))
                out.append(white(p.text, 0.92))
                if let zh = p.zh {  // 譯文緊貼在該段下方，縮排淡 cyan
                    let t = "\n　" + zh.replacingOccurrences(of: "\n\n", with: "\n　")
                    out.append(NSAttributedString(string: t, attributes: [
                        .font: NSFont.systemFont(ofSize: 11.5 * scale),
                        .foregroundColor: NSColor.systemCyan.withAlphaComponent(0.55),
                        .paragraphStyle: para]))
                }
            }
        }
        let tail = NSMutableAttributedString()
        tail.append(white(store.pendingRaw, 0.55))
        tail.append(white(store.volatileShown, 0.38))  // 對方（系統音）即時字
        if !store.micVolatile.isEmpty {  // 我（mic）即時字 — 另起一行標 🎤、淡 cyan 與對方區分
            if tail.length > 0 { tail.append(white("\n", 0.5)) }
            tail.append(NSAttributedString(string: "🎤 " + store.micVolatile, attributes: [
                .font: NSFont.systemFont(ofSize: 12 * scale),
                .foregroundColor: NSColor.systemCyan.withAlphaComponent(0.5),
                .paragraphStyle: para]))
        }
        if tail.length > 0 {
            if !store.polishedBlocks.isEmpty { out.append(white("\n", 0.55)) }
            out.append(tail)
        }
        return out
    }

    private static func headerLine(_ block: PolishedBlock, scale: CGFloat, para: NSParagraphStyle) -> NSAttributedString {
        func part(_ s: String, _ opacity: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5 * scale, weight: weight),
                .foregroundColor: NSColor.white.withAlphaComponent(opacity),
                .paragraphStyle: para])
        }
        func cyan(_ s: String, _ opacity: CGFloat) -> NSAttributedString {  // 分人講者字母
            NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5 * scale, weight: .semibold),
                .foregroundColor: NSColor.systemCyan.withAlphaComponent(opacity),
                .paragraphStyle: para])
        }
        let h = NSMutableAttributedString()
        h.append(part(Self.timeFormat.string(from: block.at), 0.4))
        h.append(part("  \(block.isMic ? "🎤" : "🔊") \(block.locale.hasPrefix("zh") ? "中" : "EN")", 0.4, .medium))
        if let speaker = block.speaker {  // 分人開啟時系統音的講者標
            h.append(cyan("  " + speaker, 0.85))
        }
        if let source = block.source {
            h.append(part("  " + String(source.prefix(28)), 0.5, .medium))
        }
        var tail = "  · \(block.charCount) 字"
        if let dur = block.durationSeconds, dur >= 1 { tail += " · \(Int(dur))s" }
        h.append(part(tail, 0.3, .regular))
        return h
    }

    @MainActor
    final class Coordinator: NSObject {
        let store: TranscriptStore
        init(store: TranscriptStore) { self.store = store }

        @objc func copyAll() {
            let all = [store.polished, store.pendingRaw, store.volatileShown]
                .filter { !$0.isEmpty }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(all, forType: .string)
        }
        @objc func clearAll() { store.clearTranscript() }
    }
}

/// 逐字稿專用 NSTextView：右鍵選單完全自訂 — 複製(選取) / 複製逐字稿 / 清除，
/// 砍掉系統文字選單的 Look Up / Translate / Writing Tools / Open / Show in Finder…
private final class KiloTextView: NSTextView {
    weak var coordinator: SelectableTranscript.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(NSMenuItem(title: "複製", action: #selector(NSText.copy(_:)), keyEquivalent: ""))
        m.addItem(.separator())
        let all = NSMenuItem(title: "複製逐字稿", action: #selector(SelectableTranscript.Coordinator.copyAll), keyEquivalent: "")
        all.target = coordinator
        m.addItem(all)
        let clear = NSMenuItem(title: "清除逐字稿", action: #selector(SelectableTranscript.Coordinator.clearAll), keyEquivalent: "")
        clear.target = coordinator
        m.addItem(clear)
        return m
    }
}
