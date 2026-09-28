import CoreGraphics

public struct AccessibilityWindowAttributes: Equatable, Sendable {
    public let role: String
    public let subrole: String?
    public let isMinimized: Bool
    public let position: CGPoint
    public let size: CGSize
    public let positionIsSettable: Bool
    public let sizeIsSettable: Bool
    public let presentationState: WindowPresentationState

    public init(
        role: String,
        subrole: String? = nil,
        isMinimized: Bool,
        position: CGPoint,
        size: CGSize,
        positionIsSettable: Bool,
        sizeIsSettable: Bool,
        presentationState: WindowPresentationState = .unknown
    ) {
        self.role = role
        self.subrole = subrole
        self.isMinimized = isMinimized
        self.position = position
        self.size = size
        self.positionIsSettable = positionIsSettable
        self.sizeIsSettable = sizeIsSettable
        self.presentationState = presentationState
    }
}

public enum WindowEligibility: Equatable, Sendable {
    case eligible(isResizable: Bool)
    case excluded
}

public enum WindowClassifier {
    public static func classify(_ attributes: AccessibilityWindowAttributes) -> WindowEligibility {
        guard attributes.role == "AXWindow",
              !attributes.isMinimized else {
            return .excluded
        }

        let transientSubroles: Set<String> = [
            "AXDialog",
            "AXSystemDialog",
            "AXSheet",
            "AXFloatingWindow",
            "AXPopover"
        ]
        guard !transientSubroles.contains(attributes.subrole ?? "") else {
            return .excluded
        }
        guard !isAuxiliary(attributes.subrole) else {
            return .excluded
        }
        // Native full-screen windows live in a dedicated macOS Space. Their
        // geometry attributes can be temporarily non-settable until the
        // window exits that Space, but the full-screen transition itself is
        // the supported route to make them movable. Do not apply this escape
        // hatch to ordinary windows: those remain excluded so Stage Manager
        // and other hidden non-movable surfaces cannot be moved.
        guard attributes.positionIsSettable || attributes.presentationState.isFullScreen == true else {
            return .excluded
        }
        return .eligible(isResizable: attributes.sizeIsSettable)
    }

    public static func skipReason(for attributes: AccessibilityWindowAttributes) -> WindowSkipReason? {
        guard attributes.role == "AXWindow" else { return .nonWindow }
        guard !attributes.isMinimized else { return .minimized }
        let transientSubroles: Set<String> = [
            "AXDialog", "AXSystemDialog", "AXSheet", "AXFloatingWindow", "AXPopover"
        ]
        if transientSubroles.contains(attributes.subrole ?? "") { return .transient }
        if isAuxiliary(attributes.subrole) { return .auxiliary }
        guard attributes.positionIsSettable || attributes.presentationState.isFullScreen == true else {
            return .nonMovable
        }
        return nil
    }

    private static func isAuxiliary(_ subrole: String?) -> Bool {
        let auxiliarySubroles: Set<String> = [
            "AXSystemFloatingWindow",
            "AXUnknown",
            "AXUtilityWindow",
            "AXDesktopWidget",
            "AXWidget",
            "AXDesktop",
            "AXDockWindow",
            "AXMenu",
            "AXHelpTag"
        ]
        return auxiliarySubroles.contains(subrole ?? "")
    }

}
