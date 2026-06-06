import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// 一次捕捉的素材：文字 role 收文字、其他收 bounds 截圖。
enum AssetKind {
    case text(String)
    case image(NSImage)
}

struct Asset: Identifiable {
    let id = UUID()
    let kind: AssetKind
    let source: String
    let capturedAt: Date

    var typeLabel: String {
        switch kind {
        case .text: return "text"
        case .image: return "image"
        }
    }

    var summary: String {
        switch kind {
        case .text(let s):
            let oneLine = s.replacingOccurrences(of: "\n", with: " ")
            return String(oneLine.prefix(80))
        case .image(let img):
            return "image \(Int(img.size.width))×\(Int(img.size.height))"
        }
    }

    /// 截圖 → PNG（餵 codex `-i`）。
    func pngData() -> Data? {
        guard case .image(let img) = kind,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// 元素 → Asset：文字 role 直接取 AX value/title，其他用 SCK 截 bounds。
/// Ported from zyx1121/shake。
@MainActor
final class Capturer {
    func capture(info: OverlayInfo) async -> Asset? {
        if isTextRole(info.role), let text = preferredText(from: info), !text.isEmpty {
            return Asset(
                kind: .text(text),
                source: sourceLabel(info: info),
                capturedAt: Date()
            )
        }
        guard let frame = info.frame else { return nil }
        if let img = await screenshot(cgRect: frame) {
            return Asset(
                kind: .image(img),
                source: sourceLabel(info: info),
                capturedAt: Date()
            )
        }
        return nil
    }

    private func isTextRole(_ role: String) -> Bool {
        switch role {
        case "AXStaticText", "AXTextField", "AXTextArea", "AXText", "AXHeading":
            return true
        default:
            return false
        }
    }

    private func preferredText(from info: OverlayInfo) -> String? {
        if !info.value.isEmpty { return info.value }
        if !info.title.isEmpty { return info.title }
        return nil
    }

    private func sourceLabel(info: OverlayInfo) -> String {
        var parts: [String] = []
        if !info.app.isEmpty { parts.append(info.app) }
        if !info.role.isEmpty { parts.append(info.role) }
        return parts.joined(separator: " · ")
    }

    private func screenshot(cgRect: CGRect) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = displayContaining(cgRect, in: content) else { return nil }
            let myBundle = Bundle.main.bundleIdentifier ?? "tw.zyx.kilo"
            let excluded = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == myBundle
            }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)

            let displayBounds = CGDisplayBounds(display.displayID)
            let localRect = CGRect(
                x: cgRect.origin.x - displayBounds.origin.x,
                y: cgRect.origin.y - displayBounds.origin.y,
                width: cgRect.width,
                height: cgRect.height
            )
            let scale = NSScreen.screens
                .first(where: { $0.cgDisplayID == display.displayID })?
                .backingScaleFactor ?? 2.0

            let config = SCStreamConfiguration()
            config.sourceRect = localRect
            config.width = max(1, Int(cgRect.width * scale))
            config.height = max(1, Int(cgRect.height * scale))
            config.showsCursor = false

            let cg = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return NSImage(cgImage: cg, size: NSSize(width: cgRect.width, height: cgRect.height))
        } catch {
            Telemetry.shake.error("screenshot error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func displayContaining(_ rect: CGRect, in content: SCShareableContent) -> SCDisplay? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for d in content.displays {
            if CGDisplayBounds(d.displayID).contains(center) {
                return d
            }
        }
        return content.displays.first
    }
}

extension NSScreen {
    var cgDisplayID: CGDirectDisplayID {
        let desc = deviceDescription
        if let n = desc[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDirectDisplayID(n.uint32Value)
        }
        return 0
    }
}
