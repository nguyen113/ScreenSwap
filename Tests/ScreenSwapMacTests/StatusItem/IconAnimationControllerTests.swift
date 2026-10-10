import AppKit
import ScreenSwapCore
import Testing
@testable import ScreenSwapMac

@Test @MainActor
func iconPackResourcesLoadAtBothScalesWithTemplateTinting() throws {
    for mode in StatusIconMode.allCases {
        let names = [mode.templateName, mode.rawValue + "DisabledTemplate"]
            + (0...12).map { mode.rawValue + String(format: "Motion%02d", $0) }
        for name in names {
            let image = try #require(StatusIconImages.image(named: name))
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
            let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
            #expect(reps.map(\.pixelsWide) == [18, 36])
            #expect(reps.map(\.pixelsHigh) == [18, 36])
            for rep in reps {
                #expect(rep.size == image.size)
                for x in 0..<rep.pixelsWide {
                    for y in 0..<rep.pixelsHigh {
                        let color = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        #expect(color.redComponent == 0 && color.greenComponent == 0 && color.blueComponent == 0)
                    }
                }
            }
        }
        let idle = try #require(StatusIconImages.image(named: mode.templateName)?.tiffRepresentation)
        #expect(StatusIconImages.image(named: mode.rawValue + "Motion00")?.tiffRepresentation == idle)
        #expect(StatusIconImages.image(named: mode.rawValue + "Motion12")?.tiffRepresentation == idle)
    }
    #expect(StatusIconImages.image(named: "Unavailable") != nil)
    #expect(StatusIconImages.appIcon != nil)
    #expect(StatusIconImages.appIcon?.isTemplate == false)
}

@Test @MainActor
func successfulActionPlaysThirteenFramesAtPackTimingAndSettlesOnSwap() async {
    for mode in StatusIconMode.allCases {
        var names: [String] = []
        var deadlines: [ContinuousClock.Instant] = []
        let controller = IconAnimationController(
            setImage: { names.append($0) }, reduceMotion: { false }, observeAccessibility: false,
            waitUntil: { deadlines.append($0) }
        )
        controller.completed(mode, outcome: .success(attempted: 1, succeeded: 1))
        await controller.playback?.value
        let expectedFrames: [String] = (0...12).map {
            mode.rawValue + String(format: "Motion%02d", $0)
        }
        let expectedNames: [String] = ["SwapTemplate"] + expectedFrames + ["SwapTemplate"]
        #expect(names == expectedNames)
        #expect(deadlines.count == 12)
        let elapsed = deadlines.first!.duration(to: deadlines.last!)
        let expected = mode.duration * 11 / 12
        #expect(elapsed >= expected - .nanoseconds(1) && elapsed <= expected + .nanoseconds(1))
        #expect(controller.assetName == "SwapTemplate")
        #expect(controller.playback == nil)
    }
}

@Test @MainActor
func failurePartialSuccessAndNoOpNeverAnimate() {
    for outcome in [SwapOutcome.noMoves, .noSelection, .noPermission, .unsupportedDisplayCount(1),
                    .alreadyRunning, .displayTopologyChanged,
                    .partialFailure(attempted: 2, succeeded: 1, failed: 1),
                    .success(attempted: 0, succeeded: 0)] {
        var names: [String] = []
        let controller = IconAnimationController(setImage: { names.append($0) }, reduceMotion: { false }, observeAccessibility: false)
        controller.completed(.swap, outcome: outcome)
        #expect(controller.playback == nil)
        #expect(names.count == 1)
        #expect(!names[0].contains("Motion"))
        if outcome == .noPermission || outcome == .unsupportedDisplayCount(1) {
            #expect(names[0] == "SwapDisabledTemplate")
        }
    }
}

@Test @MainActor
func reducedMotionSkipsPlaybackAndCancelsItWhenEnabledDuringAnimation() async {
    var reduced = true
    var names: [String] = []
    let controller = IconAnimationController(
        setImage: { names.append($0) }, reduceMotion: { reduced }, observeAccessibility: false,
        waitUntil: { _ in reduced = true }
    )
    controller.completed(.moveLeft, outcome: .success(attempted: 1, succeeded: 1))
    #expect(controller.playback == nil)
    #expect(names == ["SwapTemplate"])
    reduced = false
    controller.completed(.moveRight, outcome: .success(attempted: 1, succeeded: 1))
    await controller.playback?.value
    #expect(names.suffix(2) == ["MoveRightMotion00", "SwapTemplate"])
    controller.show(.moveLeft, available: false)
    controller.accessibilityOptionsChanged()
    #expect(controller.assetName == "MoveLeftDisabledTemplate")
}

@Test @MainActor
func newerStatePreventsStaleAnimationFromOverwritingAvailability() async {
    var names: [String] = []
    let controller = IconAnimationController(
        setImage: { names.append($0) }, reduceMotion: { false }, observeAccessibility: false,
        waitUntil: { _ in }
    )
    controller.completed(.swap, outcome: .success(attempted: 1, succeeded: 1))
    let oldPlayback = controller.playback
    controller.show(.moveLeft, available: false)
    await oldPlayback?.value
    #expect(names == ["SwapTemplate", "MoveLeftDisabledTemplate"])
}

@Test
func moveGlyphUsesPhysicalGeometryAndAvoidsVerticalArrows() {
    func display(_ id: UInt32, x: CGFloat, y: CGFloat) -> DisplaySnapshot {
        let frame = CGRect(x: x, y: y, width: 1000, height: 800)
        return DisplaySnapshot(id: id, frame: frame, visibleFrame: frame)
    }
    let left = display(99, x: -1000, y: 0)
    let right = display(1, x: 0, y: 0)
    let above = display(2, x: 0, y: -800)
    #expect(StatusIconMode.move(from: left, to: right) == .moveRight)
    #expect(StatusIconMode.move(from: right, to: left) == .moveLeft)
    #expect(StatusIconMode.move(from: right, to: above) == nil)
}
