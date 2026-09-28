import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

public struct AccessibilityApplication: Equatable, Hashable, Sendable {
    public let processIdentifier: Int32
    public let isTerminated: Bool
    public let bundleIdentifier: String?
    /// Presentation-only. This is never used as a window identity or logged.
    public let localizedName: String?

    public init(
        processIdentifier: Int32,
        isTerminated: Bool = false,
        bundleIdentifier: String? = nil,
        localizedName: String? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.isTerminated = isTerminated
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
    }
}

public struct AccessibilityWindowHandle: Equatable, Hashable, Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

@MainActor
public protocol AccessibilityClient: AnyObject {
    func beginCapture()
    func applications() throws -> [AccessibilityApplication]
    func visibleWindows() throws -> [VisibleWindowSnapshot]
    func windows(for application: AccessibilityApplication) throws -> [AccessibilityWindowHandle]
    func attributes(for window: AccessibilityWindowHandle) throws -> AccessibilityWindowAttributes
    func setSize(_ size: CGSize, for window: AccessibilityWindowHandle) throws
    func setPosition(_ position: CGPoint, for window: AccessibilityWindowHandle) throws
    func raise(_ window: AccessibilityWindowHandle) throws
    func activateApplication(for window: AccessibilityWindowHandle) throws
    func setFullScreen(_ isFullScreen: Bool, for window: AccessibilityWindowHandle) throws
    func pressZoom(for window: AccessibilityWindowHandle) throws
    func pressFullScreen(for window: AccessibilityWindowHandle) throws
}

public extension AccessibilityClient {
    /// Fakes and clients that cannot activate an application may preserve the
    /// existing behavior. The live adapter overrides this for native
    /// full-screen Spaces, whose AX controls can reject background actions.
    func activateApplication(for window: AccessibilityWindowHandle) throws {}

    func setFullScreen(_ isFullScreen: Bool, for window: AccessibilityWindowHandle) throws {
        throw AccessibilityClientError.actionFailed
    }
}

public enum AccessibilityClientError: Error, Equatable, Sendable {
    case attributeReadFailed
    case writeFailed
    case actionFailed
    case transitionTimedOut
    case malformedValue
}

@MainActor
public final class LiveAccessibilityClient: AccessibilityClient {
    private var elements: [String: AXUIElement] = [:]
    private var processIdentifiers: [String: Int32] = [:]

    public init() {}

    public func beginCapture() {
        elements.removeAll(keepingCapacity: true)
        processIdentifiers.removeAll(keepingCapacity: true)
    }

    public func applications() throws -> [AccessibilityApplication] {
        NSWorkspace.shared.runningApplications.map {
            AccessibilityApplication(
                processIdentifier: $0.processIdentifier,
                isTerminated: $0.isTerminated,
                bundleIdentifier: $0.bundleIdentifier,
                localizedName: $0.localizedName
            )
        }
    }

    public func visibleWindows() throws -> [VisibleWindowSnapshot] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw AccessibilityClientError.attributeReadFailed
        }

        return rawWindows.compactMap { rawWindow in
            guard let processNumber = rawWindow[kCGWindowOwnerPID as String] as? NSNumber,
                  let windowNumber = rawWindow[kCGWindowNumber as String] as? NSNumber,
                  let boundsDictionary = rawWindow[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary),
                  !frame.isEmpty else {
                return nil
            }
            return VisibleWindowSnapshot(
                processIdentifier: processNumber.int32Value,
                frame: frame,
                windowNumber: windowNumber.uint32Value
            )
        }
    }

    public func windows(for application: AccessibilityApplication) throws -> [AccessibilityWindowHandle] {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let value = try copyAttribute(kAXWindowsAttribute as CFString, from: appElement)
        guard let axWindows = value as? [AXUIElement] else {
            throw AccessibilityClientError.malformedValue
        }

        return axWindows.map { element in
            let token = UUID().uuidString
            elements[token] = element
            processIdentifiers[token] = application.processIdentifier
            return AccessibilityWindowHandle(token: token)
        }
    }

    public func attributes(for window: AccessibilityWindowHandle) throws -> AccessibilityWindowAttributes {
        guard let element = elements[window.token] else {
            throw AccessibilityClientError.attributeReadFailed
        }
        let role = try stringAttribute(kAXRoleAttribute as CFString, from: element)
        let subrole = try optionalStringAttribute(kAXSubroleAttribute as CFString, from: element)
        let minimized = try boolAttribute(kAXMinimizedAttribute as CFString, from: element)
        let position = try pointAttribute(kAXPositionAttribute as CFString, from: element)
        let size = try sizeAttribute(kAXSizeAttribute as CFString, from: element)
        let positionSettable = try isSettable(kAXPositionAttribute as CFString, on: element)
        let sizeSettable = try isSettable(kAXSizeAttribute as CFString, on: element)
        let presentationState = presentationState(for: element)
        let title = try optionalStringAttribute(kAXTitleAttribute as CFString, from: element)
        return AccessibilityWindowAttributes(
            role: role,
            subrole: subrole,
            isMinimized: minimized,
            position: position,
            size: size,
            positionIsSettable: positionSettable,
            sizeIsSettable: sizeSettable,
            presentationState: presentationState,
            title: title
        )
    }

    public func setSize(_ size: CGSize, for window: AccessibilityWindowHandle) throws {
        guard let element = elements[window.token] else {
            throw AccessibilityClientError.writeFailed
        }
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value), AXUIElementSetAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            axValue
        ) == .success else {
            throw AccessibilityClientError.writeFailed
        }
    }

    public func setPosition(_ position: CGPoint, for window: AccessibilityWindowHandle) throws {
        guard let element = elements[window.token] else {
            throw AccessibilityClientError.writeFailed
        }
        var value = position
        guard let axValue = AXValueCreate(.cgPoint, &value), AXUIElementSetAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            axValue
        ) == .success else {
            throw AccessibilityClientError.writeFailed
        }
    }

    public func raise(_ window: AccessibilityWindowHandle) throws {
        guard let element = elements[window.token],
              AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success else {
            throw AccessibilityClientError.actionFailed
        }
    }

    public func activateApplication(for window: AccessibilityWindowHandle) throws {
        guard let processIdentifier = processIdentifiers[window.token],
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              // Activating every window of the application can surface a
              // second window in the source Space and obscure a window that
              // ScreenSwap has just moved. Default activation is sufficient
              // to make the target full-screen window actionable.
              application.activate(options: []) else {
            throw AccessibilityClientError.actionFailed
        }
    }

    public func setFullScreen(_ isFullScreen: Bool, for window: AccessibilityWindowHandle) throws {
        guard let element = elements[window.token] else {
            throw AccessibilityClientError.actionFailed
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, "AXFullScreen" as CFString, &settable) == .success,
              settable.boolValue,
              AXUIElementSetAttributeValue(
                  element,
                  "AXFullScreen" as CFString,
                  isFullScreen ? kCFBooleanTrue : kCFBooleanFalse
              ) == .success else {
            throw AccessibilityClientError.actionFailed
        }
    }

    public func pressZoom(for window: AccessibilityWindowHandle) throws {
        try pressAction(kAXZoomButtonAttribute as CFString, for: window)
    }

    public func pressFullScreen(for window: AccessibilityWindowHandle) throws {
        try pressAction(kAXFullScreenButtonAttribute as CFString, for: window)
    }

    private func pressAction(_ buttonAttribute: CFString, for window: AccessibilityWindowHandle) throws {
        guard let element = elements[window.token],
              let button = optionalElementAttribute(buttonAttribute, from: element),
              AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            throw AccessibilityClientError.actionFailed
        }
    }

    private func copyAttribute(_ attribute: CFString, from element: AXUIElement) throws -> CFTypeRef {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            throw AccessibilityClientError.attributeReadFailed
        }
        return value
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) throws -> String {
        let value = try copyAttribute(attribute, from: element)
        guard let string = value as? String else {
            throw AccessibilityClientError.malformedValue
        }
        return string
    }

    private func optionalStringAttribute(_ attribute: CFString, from element: AXUIElement) throws -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success || result == .noValue else {
            throw AccessibilityClientError.attributeReadFailed
        }
        return value as? String
    }

    private func boolAttribute(_ attribute: CFString, from element: AXUIElement) throws -> Bool {
        let value = try copyAttribute(attribute, from: element)
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw AccessibilityClientError.malformedValue
        }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private func pointAttribute(_ attribute: CFString, from element: AXUIElement) throws -> CGPoint {
        let value = try copyAttribute(attribute, from: element)
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            throw AccessibilityClientError.malformedValue
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { throw AccessibilityClientError.malformedValue }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            throw AccessibilityClientError.malformedValue
        }
        return point
    }

    private func sizeAttribute(_ attribute: CFString, from element: AXUIElement) throws -> CGSize {
        let value = try copyAttribute(attribute, from: element)
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            throw AccessibilityClientError.malformedValue
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { throw AccessibilityClientError.malformedValue }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            throw AccessibilityClientError.malformedValue
        }
        return size
    }

    private func isSettable(_ attribute: CFString, on element: AXUIElement) throws -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute, &settable) == .success else {
            throw AccessibilityClientError.attributeReadFailed
        }
        return settable.boolValue
    }

    private func presentationState(for element: AXUIElement) -> WindowPresentationState {
        let zoomButton = optionalElementAttribute(kAXZoomButtonAttribute as CFString, from: element)
        let fullScreenButton = optionalElementAttribute(kAXFullScreenButtonAttribute as CFString, from: element)
        return WindowPresentationState(
            isZoomed: buttonState(zoomButton),
            // The full-screen button does not consistently expose a selected
            // or value state. The window-level AXFullScreen attribute is the
            // canonical state; retain the button as a compatibility fallback
            // for apps that omit it.
            isFullScreen: optionalBoolAttribute("AXFullScreen" as CFString, from: element) ?? buttonState(fullScreenButton),
            canToggleZoom: zoomButton != nil,
            canToggleFullScreen: fullScreenButton != nil
        )
    }

    private func optionalElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func optionalBoolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        return (value as? NSNumber)?.boolValue
    }

    private func buttonState(_ button: AXUIElement?) -> Bool? {
        guard let button else { return nil }
        for attribute in [kAXSelectedAttribute as CFString, kAXValueAttribute as CFString] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(button, attribute, &value) == .success,
                  let value else {
                continue
            }
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return CFBooleanGetValue((value as! CFBoolean))
            }
            if let number = value as? NSNumber {
                return number.boolValue
            }
        }
        return nil
    }
}
