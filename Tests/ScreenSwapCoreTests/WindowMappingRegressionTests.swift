import Foundation
import Testing
@testable import ScreenSwapCore

private func expectClose(_ lhs: CGFloat, _ rhs: CGFloat) {
    #expect(abs(lhs - rhs) < 0.0001)
}

private func display(_ id: UInt32, frame: CGRect, visible: CGRect? = nil) -> DisplaySnapshot {
    DisplaySnapshot(id: id, frame: frame, visibleFrame: visible ?? frame)
}

@Test
func normalizationUsesOffsetVisibleFrameOrigin() {
    let normalized = WindowMappingEngine().normalize(
        windowFrame: CGRect(x: 250, y: 150, width: 400, height: 200),
        in: CGRect(x: 100, y: 50, width: 1200, height: 800)
    )
    #expect(normalized == NormalizedWindowGeometry(x: 0.125, y: 0.125, width: 1.0 / 3.0, height: 0.25))
}

@Test
func projectionHandlesUnequalResolutionAspectRatioAndInsets() {
    let engine = WindowMappingEngine()
    let source = CGRect(x: 0, y: 40, width: 1600, height: 860)
    let destination = CGRect(x: 1600, y: 0, width: 1080, height: 1920)
    let normalized = engine.normalize(windowFrame: CGRect(x: 400, y: 255, width: 800, height: 430), in: source)
    let projected = engine.project(normalized: normalized, onto: destination)
    expectClose(projected.minX, 1870)
    expectClose(projected.minY, 480)
    expectClose(projected.width, 540)
    expectClose(projected.height, 960)
}

@Test
func projectionSupportsLandscapeToPortrait() {
    let engine = WindowMappingEngine()
    let normalized = engine.normalize(
        windowFrame: CGRect(x: 960, y: 400, width: 640, height: 360),
        in: CGRect(x: 0, y: 0, width: 1920, height: 1080)
    )
    let projected = engine.project(
        normalized: normalized,
        onto: CGRect(x: 1920, y: 0, width: 1080, height: 1920)
    )
    #expect(projected == CGRect(x: 2460, y: 711.1111111111111, width: 360, height: 640))
}

@Test
func clampKeepsFrameInsideEachDestinationEdge() {
    let engine = WindowMappingEngine()
    let destination = CGRect(x: 100, y: 200, width: 800, height: 600)
    #expect(engine.clamp(frame: CGRect(x: 0, y: 300, width: 200, height: 100), to: destination).minX == 100)
    #expect(engine.clamp(frame: CGRect(x: 700, y: 300, width: 300, height: 100), to: destination).maxX == 900)
    #expect(engine.clamp(frame: CGRect(x: 300, y: 0, width: 200, height: 100), to: destination).minY == 200)
    #expect(engine.clamp(frame: CGRect(x: 300, y: 750, width: 200, height: 100), to: destination).maxY == 800)
}

@Test
func clampPreservesValidPartiallyOffscreenSize() {
    let destination = CGRect(x: 100, y: 200, width: 800, height: 600)
    let result = WindowMappingEngine().clamp(
        frame: CGRect(x: 50, y: 250, width: 200, height: 150),
        to: destination
    )
    #expect(result == CGRect(x: 100, y: 250, width: 200, height: 150))
}

@Test
func centerOwnershipCoversAAndBAndSharedBoundary() {
    let a = display(1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let b = display(2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
    let engine = WindowMappingEngine()
    #expect(engine.sourceDisplayID(for: CGRect(x: 100, y: 100, width: 100, height: 100), displayA: a, displayB: b) == 1)
    #expect(engine.sourceDisplayID(for: CGRect(x: 1500, y: 100, width: 100, height: 100), displayA: a, displayB: b) == 2)
    #expect(engine.sourceDisplayID(for: CGRect(x: 900, y: 100, width: 200, height: 100), displayA: a, displayB: b) == 1)
}

@Test
func swapPlanHandlesEmptyMixedOrderAndUnknownDisplayIDs() {
    let a = display(10, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let b = display(20, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
    let unknown = WindowSnapshot(
        id: WindowID(processIdentifier: 1, accessibilityIdentifier: "unknown"),
        sourceDisplayID: 99,
        frame: CGRect(x: 0, y: 0, width: 20, height: 20)
    )
    let onB = WindowSnapshot(
        id: WindowID(processIdentifier: 2, accessibilityIdentifier: "b"),
        sourceDisplayID: 20,
        frame: CGRect(x: 1200, y: 100, width: 200, height: 100)
    )
    let onA = WindowSnapshot(
        id: WindowID(processIdentifier: 3, accessibilityIdentifier: "a"),
        sourceDisplayID: 10,
        frame: CGRect(x: 100, y: 100, width: 200, height: 100)
    )
    let engine = WindowMappingEngine()
    #expect(engine.makeSwapMoves(windows: [], displayA: a, displayB: b).isEmpty)
    let moves = engine.makeSwapMoves(windows: [unknown, onB, onA], displayA: a, displayB: b)
    #expect(moves.map(\.windowID) == [onB.id, onA.id])
}

@Test
func spanningUsesFullFrameEvenWhenVisibleFrameDoesNotOverlap() {
    let a = display(
        1,
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visible: CGRect(x: 0, y: 20, width: 1000, height: 780)
    )
    let b = display(
        2,
        frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
        visible: CGRect(x: 1000, y: 20, width: 1000, height: 780)
    )
    let window = WindowSnapshot(
        id: WindowID(processIdentifier: 4, accessibilityIdentifier: "full-frame"),
        sourceDisplayID: 1,
        frame: CGRect(x: 950, y: 100, width: 100, height: 100)
    )
    #expect(WindowMappingEngine().makeSwapMoves(windows: [window], displayA: a, displayB: b).isEmpty)
}
