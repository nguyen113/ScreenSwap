import CoreGraphics
import Testing
@testable import ScreenSwapMac

@Test
func focusedWindowKeyResolverUsesProcessAndFrameRatherThanTitleOrListOrder() {
    let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
    let windows = [
        VisibleWindowSnapshot(processIdentifier: 20, frame: frame, windowNumber: 99),
        VisibleWindowSnapshot(processIdentifier: 10, frame: CGRect(x: 800, y: 100, width: 400, height: 300), windowNumber: 2),
        VisibleWindowSnapshot(processIdentifier: 10, frame: frame, windowNumber: 1)
    ]

    #expect(FocusedWindowKeyResolver.resolve(processIdentifier: 10, frame: frame, visibleWindows: windows) ==
            RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 1))
    #expect(FocusedWindowKeyResolver.resolve(processIdentifier: 30, frame: frame, visibleWindows: windows) == nil)
}
