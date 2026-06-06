import AppKit
import Foundation
import QuartzCore

/// 游標晃動偵測：0.4s 內 ≥4 次方向反轉且總位移 ≥200px。
/// Ported from zyx1121/shake（驗證過的參數，不動）。
@MainActor
final class ShakeDetector {
    struct Config {
        var windowSeconds: TimeInterval = 0.4
        var minReversals: Int = 4
        var minTotalDistance: CGFloat = 200
        var cooldownSeconds: TimeInterval = 0.8
        var deltaNoiseFloor: CGFloat = 1.0
    }

    private struct Sample {
        let t: TimeInterval
        let dx: CGFloat
        let dy: CGFloat
    }

    var config: Config
    var onShake: () -> Void = {}
    var onMove: (NSPoint) -> Void = { _ in }

    private var samples: [Sample] = []
    private var lastTriggerAt: TimeInterval = 0
    private var lastLocation: NSPoint?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(config: Config = .init()) {
        self.config = config
    }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        samples.removeAll()
        lastLocation = nil
    }

    private func handle(_ event: NSEvent) {
        let now = CACurrentMediaTime()
        let loc = NSEvent.mouseLocation
        var dx = event.deltaX
        var dy = event.deltaY
        if dx == 0, dy == 0, let last = lastLocation {
            dx = loc.x - last.x
            dy = loc.y - last.y
        }
        lastLocation = loc
        onMove(loc)

        samples.append(.init(t: now, dx: dx, dy: dy))
        let cutoff = now - config.windowSeconds
        while let first = samples.first, first.t < cutoff {
            samples.removeFirst()
        }
        guard now - lastTriggerAt >= config.cooldownSeconds else { return }
        if isShake() {
            lastTriggerAt = now
            samples.removeAll()
            onShake()
        }
    }

    private func isShake() -> Bool {
        guard samples.count >= config.minReversals + 1 else { return false }

        let absX = samples.reduce(CGFloat(0)) { $0 + abs($1.dx) }
        let absY = samples.reduce(CGFloat(0)) { $0 + abs($1.dy) }
        let useX = absX >= absY
        let totalDistance = max(absX, absY)
        guard totalDistance >= config.minTotalDistance else { return false }

        var reversals = 0
        var prevSign = 0
        for s in samples {
            let v = useX ? s.dx : s.dy
            let sign: Int
            if v > config.deltaNoiseFloor {
                sign = 1
            } else if v < -config.deltaNoiseFloor {
                sign = -1
            } else {
                sign = 0
            }
            if sign != 0 {
                if prevSign != 0, sign != prevSign {
                    reversals += 1
                }
                prevSign = sign
            }
        }
        return reversals >= config.minReversals
    }
}
