import CoreGraphics
import Testing
@testable import ScreenSwapMac

@Test
func visibleWindowMatcherAcceptsNearbyQuartzBoundsForTheSameApplication() {
    let candidate = VisibleWindowSnapshot(
        processIdentifier: 100,
        frame: CGRect(x: 97, y: 92, width: 308, height: 224)
    )

    #expect(VisibleWindowMatcher.matchIndex(
        processIdentifier: 100,
        frame: CGRect(x: 100, y: 100, width: 300, height: 200),
        candidates: [candidate]
    ) == 0)
}

@Test
func visibleWindowMatcherRejectsDifferentApplicationsAndUnrelatedFrames() {
    let frame = CGRect(x: 100, y: 100, width: 300, height: 200)

    #expect(VisibleWindowMatcher.matchIndex(
        processIdentifier: 100,
        frame: frame,
        candidates: [VisibleWindowSnapshot(processIdentifier: 101, frame: frame)]
    ) == nil)
    #expect(VisibleWindowMatcher.matchIndex(
        processIdentifier: 100,
        frame: frame,
        candidates: [VisibleWindowSnapshot(
            processIdentifier: 100,
            frame: CGRect(x: 800, y: 600, width: 300, height: 200)
        )]
    ) == nil)
}

@Test
func visibleWindowMatcherPrefersPhysicalWindowOverContainedTooltip() {
    let frame = CGRect(x: 0, y: 30, width: 961, height: 968)
    let tooltip = VisibleWindowSnapshot(processIdentifier: 100,
        frame: CGRect(x: 16, y: 46, width: 66, height: 20), windowNumber: 9)
    let window = VisibleWindowSnapshot(processIdentifier: 100, frame: frame, windowNumber: 41)
    #expect(VisibleWindowMatcher.matchIndex(processIdentifier: 100, frame: frame,
                                          candidates: [tooltip, window]) == 1)
    #expect(VisibleWindowMatcher.matchIndex(processIdentifier: 100, frame: frame,
                                          candidates: [tooltip]) == nil)
}

@Test
func visibleWindowMatcherRejectsStageManagerThumbnailForFullSizeAXWindow() {
    #expect(VisibleWindowMatcher.matchIndex(processIdentifier: 100,
        frame: CGRect(x: 0, y: 30, width: 961, height: 968),
        candidates: [VisibleWindowSnapshot(processIdentifier: 100,
                     frame: CGRect(x: 0, y: 30, width: 126, height: 126), windowNumber: 41)]) == nil)
}
