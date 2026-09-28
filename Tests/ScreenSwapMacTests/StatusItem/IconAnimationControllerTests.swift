import Testing
@testable import ScreenSwapMac

@Test @MainActor
func iconStateDoesNotLoopForOneHoverAndResetsOnExit() {
    let controller = IconAnimationController()
    #expect(controller.pointerEntered(reduceMotion: false))
    #expect(controller.state == .hoverSwap)
    #expect(!controller.pointerEntered(reduceMotion: false))
    #expect(controller.state == .hoverSwap)
    controller.pointerExited()
    #expect(controller.state == .idle)
}

@Test @MainActor
func iconStateUsesStaticHoverTreatmentWhenReduceMotionIsEnabled() {
    let controller = IconAnimationController()
    #expect(!controller.pointerEntered(reduceMotion: true))
    #expect(controller.state == .hoverSwap)
}
