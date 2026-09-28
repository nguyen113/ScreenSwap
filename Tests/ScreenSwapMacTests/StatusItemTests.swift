import AppKit
import CoreGraphics
import ScreenSwapCore
import Testing
@testable import ScreenSwapMac

@Test
func statusItemUsesExplicitSwapLabel() {
    #expect(StatusItemAppearance.title == "Swap")
}

@Test
func commandURLAcceptsOnlyExplicitSwapCommand() {
    #expect(ScreenSwapCommandURL.isSwapCommand(URL(string: "screenswap://swap")!))
    #expect(ScreenSwapCommandURL.isSwapCommand(URL(string: "screenswap://swap/")!))
    #expect(ScreenSwapCommandURL.isDiagnosticsCommand(URL(string: "screenswap://diagnostics")!))
    #expect(ScreenSwapCommandURL.isDiagnosticsCommand(URL(string: "screenswap://diagnostics/")!))
    #expect(!ScreenSwapCommandURL.isSwapCommand(URL(string: "screenswap://quit")!))
    #expect(!ScreenSwapCommandURL.isDiagnosticsCommand(URL(string: "screenswap://swap")!))
    #expect(!ScreenSwapCommandURL.isSwapCommand(URL(string: "https://swap")!))
    #expect(!ScreenSwapCommandURL.isSwapCommand(URL(string: "screenswap://swap/extra")!))
    #expect(!ScreenSwapCommandURL.isDiagnosticsCommand(URL(string: "screenswap://diagnostics/extra")!))
}

@Test
@MainActor
func statusActionRequestsPermissionOnceAndRestoresEnabledState() {
    let auth = StatusFakeAuthorizer(trusted: false)
    let windows = StatusFakeWindows()
    let coordinator = SwapCoordinator(
        authorization: auth,
        displays: StatusFakeDisplays(),
        windowProvider: windows,
        windowApplying: windows
    )
    let handler = StatusItemActionHandler(coordinator: coordinator, authorization: auth)
    #expect(handler.handleClick() == .noPermission)
    #expect(handler.handleClick() == .noPermission)
    #expect(auth.requestCount == 1)
    #expect(handler.isEnabled)
    #expect(handler.tooltip.contains("click again"))
    #expect(handler.feedback == StatusItemFeedbackCatalog.feedback(for: .noPermission))
}

@Test
func statusFeedbackCatalogProvidesImmediateSafePayloadForEveryOutcome() {
    let cases: [(SwapOutcome, String, String)] = [
        (
            .success(attempted: 4, succeeded: 4),
            "ScreenSwap complete",
            "Swapped 4 of 4 window(s)."
        ),
        (
            .partialFailure(attempted: 4, succeeded: 3, failed: 1),
            "ScreenSwap partially complete",
            "Moved 3 of 4 window(s); 1 failed."
        ),
        (
            .noMoves,
            "No windows swapped",
            "No eligible windows were planned for this swap."
        ),
        (
            .noPermission,
            "ScreenSwap",
            "Grant Accessibility access in System Settings, then click ScreenSwap again."
        ),
        (
            .unsupportedDisplayCount(3),
            "ScreenSwap",
            "ScreenSwap requires exactly two displays; found 3."
        ),
        (
            .alreadyRunning,
            "ScreenSwap busy",
            "A swap is already running."
        )
    ]

    for (outcome, title, message) in cases {
        #expect(StatusItemFeedbackCatalog.feedback(for: outcome) == StatusItemFeedback(title: title, message: message))
    }
}

@Test
@MainActor
func statusPopoverFeedbackUsesShortAutoDismissInterval() {
    #expect(StatusPopoverFeedbackPresenter.autoDismissInterval == 1.5)
}

@Test
@MainActor
func statusItemRoutesRightClickToMenuAndLeftClickToExactlyOneSwapAction() {
    let auth = StatusFakeAuthorizer(trusted: false)
    let windows = StatusFakeWindows()
    let coordinator = SwapCoordinator(
        authorization: auth,
        displays: StatusFakeDisplays(),
        windowProvider: windows,
        windowApplying: windows
    )
    let handler = StatusItemActionHandler(coordinator: coordinator, authorization: auth)
    let menuPresenter = StatusFakeMenuPresenter()
    let router = StatusItemClickRouter(menuPresenter: menuPresenter)
    var leftActionCount = 0

    #expect(router.route(mouseButton: .right, button: nil) {
        leftActionCount += 1
    } == .menu)
    #expect(leftActionCount == 0)
    #expect(menuPresenter.presentCount == 1)
    #expect(auth.requestCount == 0)

    #expect(router.route(mouseButton: .left, button: nil) {
        leftActionCount += 1
        _ = handler.handleClick()
    } == .swap)
    #expect(leftActionCount == 1)
    #expect(menuPresenter.presentCount == 1)
    #expect(auth.requestCount == 1)
}

@Test
@MainActor
func statusItemExitMenuContainsNativeActionThatTerminatesOnlyScreenSwap() {
    let terminator = StatusFakeTerminator()
    let menuController = StatusItemMenuController(terminator: terminator)

    #expect(menuController.menu.items.map(\.title) == ["Exit ScreenSwap"])
    menuController.exitSelected(menuController.menu.items[0])
    #expect(terminator.terminateCount == 1)
}

@MainActor
private final class StatusFakeAuthorizer: AccessibilityAuthorizing {
    var trusted: Bool
    var requestCount = 0
    init(trusted: Bool) { self.trusted = trusted }
    var isTrusted: Bool { trusted }
    func requestAccess() { requestCount += 1 }
}

@MainActor
private final class StatusFakeDisplays: DisplayProviding {
    func currentDisplays() throws -> [DisplaySnapshot] { [] }
}

@MainActor
private final class StatusFakeWindows: WindowProviding, WindowApplying {
    func captureWindows(displays: [DisplaySnapshot]) -> WindowCaptureBatch { WindowCaptureBatch(windows: []) }
    func apply(move: WindowMove, isResizable: Bool) -> WindowApplyResult { .success }
}

@MainActor
private final class StatusFakeMenuPresenter: StatusItemMenuPresenting {
    var presentCount = 0

    func present(from button: NSStatusBarButton?) {
        presentCount += 1
    }
}

@MainActor
private final class StatusFakeTerminator: ScreenSwapTerminating {
    var terminateCount = 0

    func terminate() {
        terminateCount += 1
    }
}
