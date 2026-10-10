import AppKit
import Testing
@testable import ScreenSwapMac

@Test
func preciseScrollingCyclesOnceAndIgnoresMomentum() {
    var gesture = IconScrollGesture()
    #expect(gesture.step(delta: 4, precise: true, phase: .began, momentum: [], timestamp: 1) == true)
    #expect(gesture.step(delta: 20, precise: true, phase: .changed, momentum: [], timestamp: 2) == nil)
    #expect(gesture.step(delta: 0, precise: true, phase: .ended, momentum: [], timestamp: 3) == nil)
    #expect(gesture.step(delta: 4, precise: true, phase: [], momentum: .changed, timestamp: 4) == nil)
    #expect(gesture.step(delta: -4, precise: true, phase: .began, momentum: [], timestamp: 5) == false)
}

@Test
func wheelScrollingDebouncesAndSupportsBothDirections() {
    var gesture = IconScrollGesture()
    #expect(gesture.step(delta: 0, precise: false, phase: [], momentum: [], timestamp: 1) == nil)
    #expect(gesture.step(delta: 1, precise: false, phase: [], momentum: [], timestamp: 1) == true)
    #expect(gesture.step(delta: 1, precise: false, phase: [], momentum: [], timestamp: 1.1) == nil)
    #expect(gesture.step(delta: -1, precise: false, phase: [], momentum: [], timestamp: 1.3) == false)
}
