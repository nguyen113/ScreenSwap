import AppKit
import CoreGraphics
import Foundation
import ScreenSwapCore
import Testing
@testable import ScreenSwapMac

@Test
@MainActor
func clickModesRoutePrimaryAndSecondaryActionsExactlyOnce() {
    let router = StatusItemClickRouter(menuPresenter: ClickModeMenuPresenter())
    for mode in WindowActionMode.allCases {
        #expect(StatusItemMouseButton.left.actionMode(defaultMode: mode) == mode)
        #expect(StatusItemMouseButton.middle.actionMode(defaultMode: mode) == mode.secondary)
        #expect(StatusItemMouseButton.right.actionMode(defaultMode: mode) == nil)
        var actionCount = 0
        for button in [StatusItemMouseButton.left, .middle] {
            let route = router.route(mouseButton: button, button: nil, defaultMode: mode) { actionCount += 1 }
            #expect(route == (button.actionMode(defaultMode: mode) == .swap ? .swap : .move))
        }
        #expect(actionCount == 2)
        #expect(router.route(mouseButton: .right, button: nil, defaultMode: mode) { actionCount += 1 } == .menu)
        #expect(actionCount == 2)
    }
}

@Test
@MainActor
func contextMenuPersistsClickModeAndNotifiesAppearanceImmediately() {
    let suiteName = "ScreenSwapTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = ScreenSwapSettings(defaults: defaults)
    let controller = StatusItemMenuController(settings: settings)
    var changes = 0
    controller.defaultClickModeChanged = { changes += 1 }
    func modeItems() -> [NSMenuItem] {
        controller.menu.items.first { $0.title == "Default Left Click" }!.submenu!.items
    }
    #expect(modeItems().map(\.title) == ["SWAP", "MOVE"])
    #expect(modeItems().map(\.state) == [.on, .off])
    controller.perform(NSSelectorFromString("selectDefaultClickMode:"), with: modeItems()[1])
    #expect(changes == 1)
    #expect(ScreenSwapSettings(defaults: defaults).defaultClickMode == .move)
    #expect(modeItems().map(\.state) == [.off, .on])
    #expect(modeItems()[1].toolTip == "Left-click: MOVE. Middle-click: SWAP.")
    controller.perform(NSSelectorFromString("selectDefaultClickMode:"), with: modeItems()[0])
    #expect(changes == 2)
    #expect(settings.defaultClickMode == .swap)
}

@Test
func moveArrowTracksFocusAndDestinationInQuartzCoordinates() {
    let source = DisplaySnapshot(id: 77, frame: CGRect(x: 0, y: 0, width: 500, height: 500), visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 500))
    let cases: [(CGFloat, CGFloat, MoveArrowDirection, MoveArrowDirection)] = [
        (-500, 0, .left, .right), (500, 0, .right, .left),
        (0, -500, .up, .down), (0, 500, .down, .up),
        (-500, -500, .upLeft, .downRight), (500, -500, .upRight, .downLeft),
        (-500, 500, .downLeft, .upRight), (500, 500, .downRight, .upLeft),
        (500, 50, .right, .left)
    ]
    for (x, y, forward, reverse) in cases {
        let destination = DisplaySnapshot(id: 3, frame: CGRect(x: x, y: y, width: 500, height: 500), visibleFrame: CGRect(x: x, y: y, width: 500, height: 500))
        let displays = [destination, source]
        #expect(MoveArrowDirection.resolve(activeFrame: CGRect(x: 100, y: 100, width: 100, height: 100), displays: displays, pair: [77, 3]) == forward)
        #expect(MoveArrowDirection.resolve(activeFrame: CGRect(x: x + 100, y: y + 100, width: 100, height: 100), displays: displays, pair: [77, 3]) == reverse)
        #expect(StatusItemAppearance.symbolName(mode: .move, direction: forward) == forward.symbolName)
        #expect(StatusItemAppearance.symbolName(mode: .swap, direction: forward) == "arrow.left.arrow.right")
    }
}

@Test
func moveArrowCannotResolveSpanningThirdDisplayOrDisconnectedDestination() {
    let displays = (0..<3).map { index in
        DisplaySnapshot(id: UInt32(index + 1), frame: CGRect(x: index * 500, y: 0, width: 500, height: 500), visibleFrame: CGRect(x: index * 500, y: 0, width: 500, height: 500))
    }
    #expect(MoveArrowDirection.resolve(activeFrame: CGRect(x: 450, y: 50, width: 100, height: 100), displays: displays, pair: [1, 2]) == nil)
    #expect(MoveArrowDirection.resolve(activeFrame: CGRect(x: 1050, y: 50, width: 100, height: 100), displays: displays, pair: [1, 2]) == nil)
    #expect(MoveArrowDirection.resolve(activeFrame: CGRect(x: 50, y: 50, width: 100, height: 100), displays: displays, pair: [1, 4]) == nil)
    #expect(MoveArrowDirection.resolve(activeFrame: CGRect(x: 50, y: 50, width: 100, height: 100), displays: displays, pair: [1]) == nil)
    #expect(StatusItemAppearance.symbolName(mode: .move, direction: nil) == "arrow.right")
}

@Test
@MainActor
func allDirectionalIconsExistOnSupportedMacOS() {
    for direction in MoveArrowDirection.allCases {
        #expect(NSImage(systemSymbolName: direction.symbolName, accessibilityDescription: nil) != nil)
    }
}

@MainActor
private final class ClickModeMenuPresenter: StatusItemMenuPresenting {
    func present(from button: NSStatusBarButton?) {}
}
