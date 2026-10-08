import ApplicationServices
import AppKit
import CoreGraphics

@MainActor
public protocol FocusedWindowProviding: AnyObject {
    func focusedWindowKey() -> RuntimeWindowKey?
}

enum FocusedWindowKeyResolver {
    static func resolve(
        processIdentifier: Int32,
        frame: CGRect,
        visibleWindows: [VisibleWindowSnapshot]
    ) -> RuntimeWindowKey? {
        guard let index = VisibleWindowMatcher.matchIndex(
            processIdentifier: processIdentifier,
            frame: frame,
            candidates: visibleWindows
        ), let number = visibleWindows[index].windowNumber else { return nil }
        return RuntimeWindowKey(processIdentifier: processIdentifier, quartzWindowNumber: number)
    }
}

/// Resolves the current AX-focused window to a Quartz runtime identity. The
/// returned key is used for one command only; no AX handle or title is kept.
@MainActor
public final class LiveFocusedWindowProvider: FocusedWindowProviding {
    private let authorization: any AccessibilityAuthorizing
    private let client: any AccessibilityClient

    public init(authorization: any AccessibilityAuthorizing, client: any AccessibilityClient = LiveAccessibilityClient()) {
        self.authorization = authorization
        self.client = client
    }

    public func focusedWindowKey() -> RuntimeWindowKey? {
        guard authorization.isTrusted else { return nil }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.5)
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(window, &processIdentifier) == .success,
              let position = point(kAXPositionAttribute as CFString, from: window),
              let size = size(kAXSizeAttribute as CFString, from: window),
              let visible = try? client.visibleWindows() else { return nil }
        return FocusedWindowKeyResolver.resolve(
            processIdentifier: processIdentifier,
            frame: CGRect(origin: position, size: size),
            visibleWindows: visible
        )
    }

    private func point(_ attribute: CFString, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func size(_ attribute: CFString, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }
}
