import Testing
import Foundation
@testable import ScreenSwapCore

@Test
func normalizationAndProjectionRoundTripOnSameVisibleFrame() {
    let engine = WindowMappingEngine()
    let visible = CGRect(x: 100, y: 40, width: 1200, height: 760)
    let frame = CGRect(x: 220, y: 116, width: 600, height: 380)

    let normalized = engine.normalize(windowFrame: frame, in: visible)
    let projected = engine.project(normalized: normalized, onto: visible)

    #expect(projected.origin.x == frame.origin.x)
    #expect(projected.origin.y == frame.origin.y)
    #expect(projected.size.width == frame.size.width)
    #expect(projected.size.height == frame.size.height)
}

@Test
func clampingOversizedFrameUsesEntireDestination() {
    let engine = WindowMappingEngine()
    let destination = CGRect(x: 50, y: 20, width: 800, height: 500)

    #expect(
        engine.clamp(
            frame: CGRect(x: -100, y: -100, width: 1200, height: 900),
            to: destination
        ) == destination
    )
}

@Test
func swapPlanMovesEachKnownSourceToTheOtherDisplay() {
    let engine = WindowMappingEngine()
    let a = DisplaySnapshot(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 0, y: 20, width: 1000, height: 780)
    )
    let b = DisplaySnapshot(
        id: 2,
        frame: CGRect(x: 1000, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 1000, y: 30, width: 1600, height: 970)
    )

    let windows = [
        WindowSnapshot(
            id: WindowID(processIdentifier: 10, accessibilityIdentifier: "A"),
            sourceDisplayID: 1,
            frame: CGRect(x: 100, y: 98, width: 500, height: 390)
        ),
        WindowSnapshot(
            id: WindowID(processIdentifier: 20, accessibilityIdentifier: "B"),
            sourceDisplayID: 2,
            frame: CGRect(x: 1200, y: 127, width: 800, height: 485)
        )
    ]

    let moves = engine.makeSwapMoves(windows: windows, displayA: a, displayB: b)

    #expect(moves.count == 2)
    #expect(moves[0].destinationDisplayID == 2)
    #expect(moves[1].destinationDisplayID == 1)
}


@Test
func spanningWindowIsOmittedFromMovePlan() {
    let engine = WindowMappingEngine()
    let a = DisplaySnapshot(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 0, y: 20, width: 1000, height: 780)
    )
    let b = DisplaySnapshot(
        id: 2,
        frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 1000, y: 20, width: 1000, height: 780)
    )
    let spanning = WindowSnapshot(
        id: WindowID(processIdentifier: 30, accessibilityIdentifier: "span"),
        sourceDisplayID: 1,
        frame: CGRect(x: 900, y: 100, width: 300, height: 400)
    )

    #expect(engine.makeSwapMoves(windows: [spanning], displayA: a, displayB: b).isEmpty)
}

@Test
func boundaryTouchingWindowIsNotTreatedAsSpanning() {
    let engine = WindowMappingEngine()
    let a = DisplaySnapshot(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
    )
    let b = DisplaySnapshot(
        id: 2,
        frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800)
    )
    let touching = WindowSnapshot(
        id: WindowID(processIdentifier: 31, accessibilityIdentifier: "touch"),
        sourceDisplayID: 1,
        frame: CGRect(x: 800, y: 100, width: 200, height: 300)
    )

    #expect(engine.makeSwapMoves(windows: [touching], displayA: a, displayB: b).count == 1)
}
