import CoreGraphics
import Testing
@testable import ScreenSwapMac

@Test
func middleClickRequiresButtonTwoAndPressAndReleaseOnIcon() {
    let icon = CGRect(x: 500, y: 0, width: 60, height: 24)
    let inside = CGPoint(x: 530, y: 12)
    let outside = CGPoint(x: 470, y: 12)
    let key = RuntimeWindowKey(processIdentifier: 42, quartzWindowNumber: 7)
    var gesture = MiddleClickGesture()

    gesture.begin(buttonNumber: 2, point: outside, iconFrame: icon, focusedKey: key)
    #expect(gesture.end(buttonNumber: 2, point: inside, iconFrame: icon) == .ignored)

    gesture.begin(buttonNumber: 2, point: inside, iconFrame: icon, focusedKey: key)
    #expect(gesture.end(buttonNumber: 2, point: outside, iconFrame: icon) == .ignored)

    gesture.begin(buttonNumber: 1, point: inside, iconFrame: icon, focusedKey: key)
    #expect(gesture.end(buttonNumber: 1, point: inside, iconFrame: icon) == .ignored)

    gesture.begin(buttonNumber: 2, point: inside, iconFrame: icon, focusedKey: key)
    #expect(gesture.end(buttonNumber: 2, point: inside, iconFrame: icon) == .move(key))
    #expect(gesture.end(buttonNumber: 2, point: inside, iconFrame: icon) == .ignored)

    gesture.begin(buttonNumber: 2, point: inside, iconFrame: icon, focusedKey: nil)
    #expect(gesture.end(buttonNumber: 2, point: inside, iconFrame: icon) == .move(nil))
}
