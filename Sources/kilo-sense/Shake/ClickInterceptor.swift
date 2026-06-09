import AppKit
import CoreGraphics
import Foundation

/// 選取模式時攔截全域點擊（CGEventTap，需 Accessibility）：
/// 左鍵 = 捕捉游標下元素、右鍵 = 結束選取；passThroughRect（kilo 自己的視窗）放行。
/// Ported from zyx1121/shake。
final class ClickInterceptor: @unchecked Sendable {
    private let onLeftClick: @Sendable (CGPoint) -> Void
    private let onRightClick: @Sendable (CGPoint) -> Void
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let stateLock = NSLock()
    private var _intercept = false
    private var _passThroughRect: CGRect = .zero

    init(
        onLeftClick: @escaping @Sendable (CGPoint) -> Void,
        onRightClick: @escaping @Sendable (CGPoint) -> Void = { _ in }
    ) {
        self.onLeftClick = onLeftClick
        self.onRightClick = onRightClick
    }

    func start() {
        guard tap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: ClickInterceptor.cCallback,
            userInfo: opaque
        ) else {
            Telemetry.shake.error("event tap create failed — Accessibility missing?")
            return
        }
        CGEvent.tapEnable(tap: t, enable: false)
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        tap = t
        runLoopSource = src
        setIntent(false)
    }

    func setEnabled(_ on: Bool) {
        setIntent(on)
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: on)
    }

    func setPassThroughRect(_ rect: CGRect) {
        stateLock.lock(); defer { stateLock.unlock() }
        _passThroughRect = rect
    }

    private func setIntent(_ v: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        _intercept = v
    }

    private func snapshot() -> (intercept: Bool, passThrough: CGRect) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (_intercept, _passThroughRect)
    }

    private static let cCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<ClickInterceptor>.fromOpaque(refcon).takeUnretainedValue()
        return me.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            let (intercept, _) = snapshot()
            if let t = tap, intercept {
                CGEvent.tapEnable(tap: t, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown:
            let (intercept, passThrough) = snapshot()
            guard intercept else { return Unmanaged.passUnretained(event) }
            let loc = event.location
            if passThrough.contains(loc) {
                return Unmanaged.passUnretained(event)
            }
            let cb = onLeftClick
            DispatchQueue.main.async { cb(loc) }
            return nil

        case .leftMouseUp, .leftMouseDragged:
            let (intercept, passThrough) = snapshot()
            guard intercept else { return Unmanaged.passUnretained(event) }
            if passThrough.contains(event.location) {
                return Unmanaged.passUnretained(event)
            }
            return nil

        case .rightMouseDown:
            let (intercept, _) = snapshot()
            guard intercept else { return Unmanaged.passUnretained(event) }
            let loc = event.location
            let cb = onRightClick
            DispatchQueue.main.async { cb(loc) }
            return nil

        case .rightMouseUp:
            let (intercept, _) = snapshot()
            guard intercept else { return Unmanaged.passUnretained(event) }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
