@preconcurrency import ApplicationServices

@MainActor
public protocol AccessibilityAuthorizing: AnyObject {
    var isTrusted: Bool { get }
    func requestAccess()
}

@MainActor
public final class LiveAccessibilityAuthorizer: AccessibilityAuthorizing {
    public init() {}

    public var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    public func requestAccess() {
        _ = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
    }
}
