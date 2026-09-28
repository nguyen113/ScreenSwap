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
