import CoreGraphics
import Testing
@testable import ScreenSwapMac

private func attributes(
    role: String = "AXWindow",
    subrole: String? = nil,
    minimized: Bool = false,
    movable: Bool = true,
    resizable: Bool = true,
    presentationState: WindowPresentationState = .unknown
) -> AccessibilityWindowAttributes {
    AccessibilityWindowAttributes(
        role: role,
        subrole: subrole,
        isMinimized: minimized,
        position: CGPoint(x: 10, y: 20),
        size: CGSize(width: 300, height: 200),
        positionIsSettable: movable,
        sizeIsSettable: resizable,
        presentationState: presentationState
    )
}

@Test
func windowClassifierRejectsNonWindowsMinimizedSpecialAndImmovable() {
    for value in [
        attributes(role: "AXButton"),
        attributes(minimized: true),
        attributes(subrole: "AXSheet"),
        attributes(subrole: "AXDialog"),
        attributes(subrole: "AXPopover"),
        attributes(movable: false)
    ] {
        #expect(WindowClassifier.classify(value) == .excluded)
    }
}

@Test
func windowClassifierKeepsMovableNonResizableWindow() {
    #expect(WindowClassifier.classify(attributes(resizable: false)) == .eligible(isResizable: false))
}

@Test
func windowClassifierExcludesNativeFullScreenSpacesWithAnExplicitReason() {
    let nativeFullScreen = attributes(
        presentationState: WindowPresentationState(isFullScreen: true, canToggleFullScreen: true)
    )

    #expect(WindowClassifier.classify(nativeFullScreen) == .excluded)
    #expect(WindowClassifier.skipReason(for: nativeFullScreen) == .nativeFullScreenSpace)
}

@Test
func windowClassifierExcludesAuxiliaryWindowsButKeepsUnreadablePresentationState() {
    let auxiliary = attributes(subrole: "AXSystemFloatingWindow")
    let widgetLike = attributes(subrole: "AXUnknown")
    let unreadableZoom = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: CGPoint(x: 10, y: 20),
        size: CGSize(width: 300, height: 200),
        positionIsSettable: true,
        sizeIsSettable: true,
        presentationState: WindowPresentationState(canToggleZoom: true)
    )

    #expect(WindowClassifier.classify(auxiliary) == .excluded)
    #expect(WindowClassifier.skipReason(for: auxiliary) == .auxiliary)
    #expect(WindowClassifier.classify(widgetLike) == .excluded)
    #expect(WindowClassifier.skipReason(for: widgetLike) == .auxiliary)
    #expect(WindowClassifier.classify(unreadableZoom) == .eligible(isResizable: true))
    #expect(WindowClassifier.skipReason(for: unreadableZoom) == nil)
}
