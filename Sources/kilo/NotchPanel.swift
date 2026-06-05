import AppKit

/// 貼在 MacBook 瀏海下方的透明 overlay panel。
/// 配置 + 幾何取自 docs/macos-notch-overlay.md（算法源 DynamicNotchKit, MIT）。
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver                                // 蓋過選單列
        collectionBehavior = [.canJoinAllSpaces, .stationary]
    }
    override var canBecomeKey: Bool { true }
}

extension NSScreen {
    /// 瀏海矩形（無瀏海回 nil）。
    var notchFrame: NSRect? {
        guard let l = auxiliaryTopLeftArea?.width,
              let r = auxiliaryTopRightArea?.width else { return nil }
        let w = frame.width - l - r
        return NSRect(x: frame.midX - w / 2, y: frame.maxY - safeAreaInsets.top,
                      width: w, height: safeAreaInsets.top)
    }
}
