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
func statusTooltipReportsSelectedAttemptedSucceededAndFailedCounts() {
    let snapshot = WindowSnapshot(
        id: WindowID(processIdentifier: 10, accessibilityIdentifier: "window"),
        sourceDisplayID: 1,
        frame: CGRect(x: 50, y: 50, width: 100, height: 100)
    )
    let windows = StatusFakeWindows(batch: WindowCaptureBatch(windows: [CapturedWindow(snapshot: snapshot, isResizable: true)]))
    let displays = StatusFakeDisplays(values: [
        DisplaySnapshot(id: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 500), visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 500)),
        DisplaySnapshot(id: 2, frame: CGRect(x: 500, y: 0, width: 500, height: 500), visibleFrame: CGRect(x: 500, y: 0, width: 500, height: 500))
    ])
    let handler = StatusItemActionHandler(
        coordinator: SwapCoordinator(authorization: StatusFakeAuthorizer(trusted: true), displays: displays, windowProvider: windows, windowApplying: windows),
        authorization: StatusFakeAuthorizer(trusted: true)
    )

    #expect(handler.handleClick() == .success(attempted: 1, succeeded: 1))
    #expect(handler.tooltip == "ScreenSwap: selected 1, attempted 1, succeeded 1, failed 0.")
}

@Test
@MainActor
func statusItemExitMenuContainsNativeActionThatTerminatesOnlyScreenSwap() {
    let terminator = StatusFakeTerminator()
    let menuController = StatusItemMenuController(terminator: terminator)

    #expect(menuController.menu.items.map(\.title) == ["About ScreenSwap", "Settings…", "Exit ScreenSwap"])
    menuController.exitSelected(menuController.menu.items[0])
    #expect(terminator.terminateCount == 1)
}

@Test
@MainActor
func statusMenuBuildsFreshDisplayGroupsSelectionAndSpanningWarning() {
    let firstKey = RuntimeWindowKey(processIdentifier: 1, quartzWindowNumber: 10)
    let secondKey = RuntimeWindowKey(processIdentifier: 2, quartzWindowNumber: 20)
    let displays = [
        InventoryDisplay(snapshot: DisplaySnapshot(id: 2, frame: CGRect(x: 100, y: 0, width: 100, height: 100), visibleFrame: CGRect(x: 100, y: 0, width: 100, height: 100)), ordinal: 2, name: nil),
        InventoryDisplay(snapshot: DisplaySnapshot(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100)), ordinal: 1, name: "Built-in")
    ]
    let inventory = WindowInventory(displays: displays, windows: [
        InventoryWindow(key: firstKey, displayID: 1, label: "Finder — Desktop", isSelectable: true, isSpanning: false),
        InventoryWindow(key: secondKey, displayID: 2, label: "Terminal — Shell", isSelectable: true, isSpanning: false),
        InventoryWindow(key: nil, displayID: nil, label: "Browser — Wide", isSelectable: false, isSpanning: true)
    ])
    let selection = WindowSelectionStore()
    let menuController = StatusItemMenuController(
        inventoryProvider: StatusFakeInventory(inventory),
        selection: selection
    )

    #expect(menuController.menu.items.map(\.title).contains("Spanning windows — unavailable"))
    #expect(menuController.menu.items.map(\.title).contains("⚠ Browser — Wide — spanning, unavailable"))
    #expect(menuController.menu.items.map(\.title).contains("1 — Built-in"))
    #expect(menuController.menu.items.map(\.title).contains("Display 2"))
    let warning = menuController.menu.items.first { $0.title.contains("spanning, unavailable") }
    #expect(warning?.isEnabled == false)
    let group = menuController.menu.items.first { $0.title == "1 — Built-in" }!
    #expect(group.state == .on)
    menuController.perform(NSSelectorFromString("toggleGroup:"), with: group)
    #expect(!selection.isSelected(firstKey))
    #expect(selection.isSelected(secondKey))
}

@Test
@MainActor
func statusMenuShowsPermissionExplanationWithoutSelectionControls() {
    let menuController = StatusItemMenuController(inventoryProvider: StatusFakeInventory(.permissionRequired))
    #expect(menuController.menu.items.first?.title == "Accessibility permission required")
    #expect(menuController.menu.items.first?.isEnabled == false)
    #expect(menuController.menu.items.map(\.title).contains("Exit ScreenSwap"))
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
    var values: [DisplaySnapshot]
    init(values: [DisplaySnapshot] = []) { self.values = values }
    func currentDisplays() throws -> [DisplaySnapshot] { values }
}

@MainActor
private final class StatusFakeWindows: WindowProviding, WindowApplying {
    var batch: WindowCaptureBatch
    init(batch: WindowCaptureBatch = WindowCaptureBatch(windows: [])) { self.batch = batch }
    func captureWindows(displays: [DisplaySnapshot]) -> WindowCaptureBatch { batch }
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
private final class StatusFakeInventory: StatusItemInventoryProviding {
    let inventory: WindowInventory
    init(_ inventory: WindowInventory) { self.inventory = inventory }
    func currentInventory() -> WindowInventory { inventory }
}

@MainActor
private final class StatusFakeTerminator: ScreenSwapTerminating {
    var terminateCount = 0

    func terminate() {
        terminateCount += 1
    }
}
