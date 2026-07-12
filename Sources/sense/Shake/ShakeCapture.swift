import AppKit
import ApplicationServices
import Foundation
import QuartzCore

/// shake 機制的 sense 接線：晃游標 → 變暗 + 元素 spotlight → 左鍵捕捉進
/// TranscriptStore.attachments（chips 顯示、下一輪 codex 帶上）→ 右鍵 / 再晃結束。
/// 機制本體（detector / dim / probe / interceptor / capturer）ported from zyx1121/shake。
@MainActor
final class ShakeCapture {
    private let store: TranscriptStore
    private let detector = ShakeDetector()
    private let dim = DimOverlayController()
    private let probe = AXProbe()
    private let capturer = Capturer()
    private var clicker: ClickInterceptor?

    private var selecting = false
    private var dragStart: CGPoint?   // 左鍵按下點（CG 座標）— 拖過門檻 = 框選截圖，否則點擊收元素
    private var current = OverlayInfo()
    private var lastProbeAt: TimeInterval = 0
    private let probeInterval: TimeInterval = 1.0 / 30.0

    /// 選取模式開關（SummaryWindow 抬到 dim 之上 / 降回來）。
    var onSelectingChange: (Bool) -> Void = { _ in }
    /// sense 視窗的 CG frame — 選取模式中點它放行，可以邊圈選邊打字。
    var passThroughFrame: () -> CGRect = { .zero }

    init(store: TranscriptStore) {
        self.store = store
    }

    func start() {
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as NSDictionary)
        }
        detector.onShake = { [weak self] in self?.toggle() }
        detector.onMove = { [weak self] p in self?.moved(p) }
        detector.start()

        let interceptor = ClickInterceptor(
            onLeftDown: { p in
                Task { @MainActor [weak self] in self?.dragBegan(at: p) }
            },
            onLeftDragged: { p in
                Task { @MainActor [weak self] in self?.dragMoved(to: p) }
            },
            onLeftUp: { p in
                Task { @MainActor [weak self] in self?.dragEnded(at: p) }
            },
            onRightClick: { _ in
                Task { @MainActor [weak self] in self?.end() }
            })
        interceptor.start()
        clicker = interceptor
        Telemetry.shake.info("armed ax=\(AXIsProcessTrusted(), privacy: .public)")
    }

    private func toggle() {
        selecting ? end() : begin()
    }

    private func begin() {
        guard AXIsProcessTrusted() else {
            // 沒 AX 權限探不到元素也攔不到點擊 — 提示後不進選取模式
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as NSDictionary)
            Telemetry.shake.error("shake ignored — accessibility not granted")
            return
        }
        selecting = true
        NSSound.beep()
        clicker?.start()  // 啟動時建 tap 失敗（剛給權限）就趁現在重建
        clicker?.setPassThroughRect(passThroughFrame())
        clicker?.setEnabled(true)
        dim.show()
        onSelectingChange(true)
        store.touchOverlay()  // shake = overlay 的展開手勢
        probeNow(at: NSEvent.mouseLocation, force: true)
        Telemetry.shake.info("selection begin")
    }

    private func end() {
        guard selecting else { return }
        selecting = false
        dim.hide()
        clicker?.setEnabled(false)
        onSelectingChange(false)
        store.touchOverlay()  // 選取結束 overlay 留著，閒置計時重新起算
        Telemetry.shake.info("selection end attachments=\(self.store.attachments.count, privacy: .public)")
    }

    private func moved(_ p: NSPoint) {
        guard selecting, dragStart == nil else { return }  // 拖曳中只畫框、不探元素
        probeNow(at: p, force: false)
    }

    private func probeNow(at p: NSPoint, force: Bool) {
        let now = CACurrentMediaTime()
        if !force, now - lastProbeAt < probeInterval { return }
        lastProbeAt = now
        let info = probe.element(atCocoa: p) ?? OverlayInfo()
        current = info
        dim.setHighlight(info.frame)
    }

    private func clicked(at cgPoint: CGPoint) {
        guard selecting else { return }
        let info = current
        guard info.hasContent else {
            Telemetry.shake.info("click ignored — no element under cursor")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let asset = await self.capturer.capture(info: info) {
                self.store.addAttachment(asset)
                Telemetry.shake.info("captured \(asset.typeLabel, privacy: .public) — \(asset.summary, privacy: .public)")
            } else {
                Telemetry.shake.error("capture failed — no text and no frame")
            }
        }
    }

    // MARK: 左鍵 — 點擊收元素 / 拖曳框選截圖

    private func dragBegan(at p: CGPoint) {
        guard selecting else { return }
        dragStart = p
    }

    private func dragMoved(to p: CGPoint) {
        guard selecting, let s = dragStart else { return }
        dim.setHighlight(Self.rect(s, p))  // 即時畫出框選範圍
    }

    private func dragEnded(at p: CGPoint) {
        guard selecting, let s = dragStart else { return }
        dragStart = nil
        let r = Self.rect(s, p)
        if r.width > 6, r.height > 6 {
            captureRegion(r)   // 拖出範圍 → 截該區塊
        } else {
            clicked(at: p)     // 沒拖（單純點擊）→ 收游標下元素
        }
    }

    /// 框選區塊截圖 → chip（座標同 AX 元素：CG top-left，Capturer 直接吃）。
    private func captureRegion(_ rect: CGRect) {
        var info = OverlayInfo()
        info.app = "圈選區域"
        info.frame = rect
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let asset = await self.capturer.capture(info: info) {
                self.store.addAttachment(asset)
                Telemetry.shake.info("captured region \(Int(rect.width))x\(Int(rect.height))")
            } else {
                Telemetry.shake.error("region capture failed")
            }
        }
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
