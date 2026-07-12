import AppKit
import ApplicationServices

/// 游標下 UI 元素的 AX 快照。Ported from zyx1121/shake。
struct OverlayInfo {
    var app: String = ""
    var role: String = ""
    var roleDescription: String = ""
    var title: String = ""
    var value: String = ""
    var frame: CGRect?

    var hasContent: Bool {
        !app.isEmpty || !role.isEmpty || !title.isEmpty || !value.isEmpty
    }
}

@MainActor
final class AXProbe {
    private let systemWide = AXUIElementCreateSystemWide()

    func element(atCocoa cocoa: NSPoint) -> OverlayInfo? {
        guard AXIsProcessTrusted() else { return nil }
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.main
        else { return nil }
        let cgX = Float(cocoa.x)
        let cgY = Float(primary.frame.height - cocoa.y)

        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, cgX, cgY, &element)
        guard err == .success, let el = element else { return nil }

        var info = OverlayInfo()
        info.role = string(el, kAXRoleAttribute) ?? ""
        info.roleDescription = string(el, kAXRoleDescriptionAttribute) ?? ""
        info.title = string(el, kAXTitleAttribute) ?? ""
        info.value = string(el, kAXValueAttribute) ?? ""

        var pid: pid_t = 0
        if AXUIElementGetPid(el, &pid) == .success,
           let app = NSRunningApplication(processIdentifier: pid)?.localizedName {
            info.app = app
        }

        if let pos = point(el, kAXPositionAttribute), let sz = size(el, kAXSizeAttribute),
           sz.width > 0, sz.height > 0 {
            info.frame = CGRect(origin: pos, size: sz)
        }

        return info
    }

    private func string(_ el: AXUIElement, _ attr: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success,
              let value = raw as? String, !value.isEmpty else { return nil }
        return value
    }

    private func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success,
              let ref = raw, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &p) else { return nil }
        return p
    }

    private func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success,
              let ref = raw, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &s) else { return nil }
        return s
    }
}
