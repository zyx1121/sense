import AppKit
import SwiftUI

/// 放上螢幕的 panel 共同基底：對 AX tree 隱形，AXProbe 不會探到自己的 UI。
/// Ported from zyx1121/shake。
final class ShakeOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { nil }
    override func accessibilityChildren() -> [Any]? { [] }
    override func isAccessibilityElement() -> Bool { false }
}

/// 全螢幕變暗 + 游標下元素的 spotlight 挖洞。每個 screen 一片。
/// Ported from zyx1121/shake。
@MainActor
final class DimOverlayController {
    private struct Pane {
        let screen: NSScreen
        let panel: ShakeOverlayPanel
        let host: NSHostingView<DimContent>
    }

    private var panes: [Pane] = []
    private var highlightCG: CGRect?
    private let dimOpacity: Double = 0.42

    var isVisible: Bool { panes.first?.panel.isVisible == true }

    func show() {
        ensure()
        for p in panes { p.panel.orderFrontRegardless() }
        rerender()
    }

    func hide() {
        for p in panes { p.panel.orderOut(nil) }
        highlightCG = nil
        rerender()
    }

    func setHighlight(_ rect: CGRect?) {
        highlightCG = rect
        rerender()
    }

    private func ensure() {
        if !panes.isEmpty { return }
        for screen in NSScreen.screens {
            let panel = ShakeOverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = true
            panel.setFrame(screen.frame, display: false)

            let host = NSHostingView(rootView: DimContent(highlight: nil, dimOpacity: dimOpacity))
            host.frame = NSRect(origin: .zero, size: screen.frame.size)
            panel.contentView = host

            panes.append(Pane(screen: screen, panel: panel, host: host))
        }
    }

    private func rerender() {
        for p in panes {
            let local = highlightCG.flatMap { rectInLocal($0, screen: p.screen) }
            p.host.rootView = DimContent(highlight: local, dimOpacity: dimOpacity)
        }
    }

    private func rectInLocal(_ cg: CGRect, screen: NSScreen) -> CGRect? {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.main
        else { return nil }
        let primaryH = primary.frame.height
        let cocoa = screen.frame
        let screenCG = CGRect(
            x: cocoa.origin.x,
            y: primaryH - cocoa.origin.y - cocoa.height,
            width: cocoa.width,
            height: cocoa.height
        )
        let inter = cg.intersection(screenCG)
        if inter.isNull || inter.isEmpty { return nil }
        return CGRect(
            x: inter.origin.x - screenCG.origin.x,
            y: inter.origin.y - screenCG.origin.y,
            width: inter.width,
            height: inter.height
        )
    }
}

struct DimContent: View {
    let highlight: CGRect?
    let dimOpacity: Double

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    if let h = highlight {
                        path.addRoundedRect(in: h, cornerSize: CGSize(width: 6, height: 6))
                    }
                }
                .fill(Color.black.opacity(dimOpacity), style: FillStyle(eoFill: true))

                if let h = highlight {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                        .frame(width: h.width, height: h.height)
                        .position(x: h.midX, y: h.midY)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}
