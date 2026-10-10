import AppKit
import CoreGraphics
import ScreenSwapCore
import Testing
@testable import ScreenSwapMac

@Test
func statusItemUsesIconOnlyAppearance() {
    #expect(StatusItemAppearance.title.isEmpty)
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
            "ScreenSwap requires at least two active displays; found 3."
        ),
        (
            .displayTopologyChanged,
            "Display configuration changed",
            "Your display configuration changed. Try the swap again."
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
func successfulAndPartiallySuccessfulSwapsMarkMenuInventoryStale() {
    #expect(StatusItemMenuInventoryRefreshPolicy.shouldMarkStale(after: .success(attempted: 2, succeeded: 2)))
    #expect(StatusItemMenuInventoryRefreshPolicy.shouldMarkStale(after: .partialFailure(attempted: 2, succeeded: 1, failed: 1)))
    #expect(!StatusItemMenuInventoryRefreshPolicy.shouldMarkStale(after: .partialFailure(attempted: 2, succeeded: 0, failed: 2)))
    #expect(!StatusItemMenuInventoryRefreshPolicy.shouldMarkStale(after: .noMoves))
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

    router.refreshMenuInventory()
    #expect(menuPresenter.refreshCount == 1)
    router.markMenuInventoryStale()
    #expect(menuPresenter.staleCount == 1)

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
func noSelectionTooltipIncludesZeroCounts() {
    let key = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 1)
    let snapshot = WindowSnapshot(
        id: WindowID(processIdentifier: 10, accessibilityIdentifier: "unchecked"),
        sourceDisplayID: 1,
        frame: CGRect(x: 50, y: 50, width: 100, height: 100)
    )
    let selection = WindowSelectionStore()
    selection.reconcile([key])
    selection.setSelected(false, for: key)
    let windows = StatusFakeWindows(batch: WindowCaptureBatch(windows: [
        CapturedWindow(snapshot: snapshot, isResizable: true, runtimeKey: key)
    ]))
    let displays = StatusFakeDisplays(values: [
        DisplaySnapshot(id: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 500), visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 500)),
        DisplaySnapshot(id: 2, frame: CGRect(x: 500, y: 0, width: 500, height: 500), visibleFrame: CGRect(x: 500, y: 0, width: 500, height: 500))
    ])
    let handler = StatusItemActionHandler(
        coordinator: SwapCoordinator(
            authorization: StatusFakeAuthorizer(trusted: true),
            displays: displays,
            windowProvider: windows,
            windowApplying: windows,
            selection: selection
        ),
        authorization: StatusFakeAuthorizer(trusted: true)
    )

    #expect(handler.handleClick() == .noSelection)
    #expect(handler.tooltip == "ScreenSwap: no selection — selected 0, attempted 0, succeeded 0, failed 0.")
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
func statusMenuOffersFocusedWindowMoveAction() {
    let menuController = StatusItemMenuController()
    var moves = 0
    menuController.moveFocusedWindowAction = { moves += 1 }
    menuController.rebuildMenu()

    let item = menuController.menu.items.first { $0.title == "Move Focused Window to Other Display" }
    #expect(item != nil)
    menuController.perform(NSSelectorFromString("moveFocusedWindowSelected:"), with: item)
    #expect(moves == 1)
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
        InventoryWindow(key: nil, displayID: 2, label: "Safari — Full Screen", isSelectable: false, isNativeFullScreenUnsupported: true, isSpanning: false),
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
    let nativeFullScreen = menuController.menu.items.first { $0.title.contains("native full-screen, unsupported") }
    #expect(nativeFullScreen?.state == .off)
    #expect(nativeFullScreen?.isEnabled == false)
    #expect(nativeFullScreen?.toolTip?.contains("Exit full screen first") == true)
    let group = menuController.menu.items.first { $0.title == "    All windows" }!
    #expect(group.state == .on)
    menuController.perform(NSSelectorFromString("toggleGroup:"), with: group)
    #expect(!selection.isSelected(firstKey))
    #expect(selection.isSelected(secondKey))
}

@Test
@MainActor
func statusMenuSeparatesDisplayPairMembershipFromAllWindowsSelection() {
    let displays = [1, 2, 3].enumerated().map { offset, id in
        InventoryDisplay(
            snapshot: DisplaySnapshot(
                id: UInt32(id),
                frame: CGRect(x: CGFloat(offset * 100), y: 0, width: 100, height: 100),
                visibleFrame: CGRect(x: CGFloat(offset * 100), y: 0, width: 100, height: 100)
            ),
            ordinal: offset + 1,
            name: nil
        )
    }
    let first = RuntimeWindowKey(processIdentifier: 1, quartzWindowNumber: 1)
    let second = RuntimeWindowKey(processIdentifier: 1, quartzWindowNumber: 2)
    let third = RuntimeWindowKey(processIdentifier: 1, quartzWindowNumber: 3)
    let inventory = WindowInventory(
        displays: displays,
        windows: [
            InventoryWindow(key: first, displayID: 1, label: "First A", isSelectable: true, isSpanning: false),
            InventoryWindow(key: second, displayID: 1, label: "First B", isSelectable: true, isSpanning: false),
            InventoryWindow(key: third, displayID: 2, label: "Second", isSelectable: true, isSpanning: false)
        ],
        selectedDisplayIDs: [1, 2],
        primaryDisplayID: 1
    )
    let displaySelection = DisplayPairSelectionStore()
    displaySelection.reconcile(
        activeDisplays: displays.map(\.snapshot),
        primaryDisplayID: 1,
        candidateCounts: [1: 2, 2: 1]
    )
    let windowSelection = WindowSelectionStore()
    let menuController = StatusItemMenuController(
        inventoryProvider: StatusFakeInventory(inventory),
        selection: windowSelection,
        displaySelection: displaySelection
    )

    let displayThree = menuController.menu.items.first { $0.title == "Display 3" }!
    #expect(displayThree.state == .off)
    #expect(displayThree.isEnabled)
    menuController.perform(NSSelectorFromString("toggleDisplay:"), with: displayThree)
    #expect(displaySelection.frozenPair() == [1, 3])
    #expect(windowSelection.isSelected(first))
    #expect(windowSelection.isSelected(second))
    #expect(windowSelection.isSelected(third))
}

@Test
@MainActor
func statusMenuShowsPermissionExplanationWithoutSelectionControls() {
    let menuController = StatusItemMenuController(inventoryProvider: StatusFakeInventory(.permissionRequired))
    #expect(menuController.menu.items.first?.title == "Accessibility permission required")
    #expect(menuController.menu.items.first?.isEnabled == false)
    #expect(menuController.menu.items.map(\.title).contains("Exit ScreenSwap"))
}

@Test
@MainActor
func statusMenuRendersCachedInventoryWithoutRefreshingOnRebuildOrSelectionChange() {
    let key = RuntimeWindowKey(processIdentifier: 1, quartzWindowNumber: 1)
    let inventory = WindowInventory(
        displays: [InventoryDisplay(
            snapshot: DisplaySnapshot(
                id: 1,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
            ),
            ordinal: 1,
            name: nil
        )],
        windows: [InventoryWindow(key: key, displayID: 1, label: "Finder", isSelectable: true, isSpanning: false)]
    )
    let provider = StatusFakeInventory(inventory)
    let selection = WindowSelectionStore()
    let menuController = StatusItemMenuController(inventoryProvider: provider, selection: selection)

    #expect(provider.currentInventoryCallCount == 1)
    menuController.rebuildMenu()
    #expect(provider.currentInventoryCallCount == 1)

    let item = menuController.menu.items.first { $0.title == "        Finder" }!
    menuController.perform(NSSelectorFromString("toggleWindow:"), with: item)
    #expect(provider.currentInventoryCallCount == 1)
    #expect(!selection.isSelected(key))
}

@Test
@MainActor
func statusMenuRefreshActionIsTheOnlyPathThatCollectsAnotherInventorySnapshot() {
    let initial = WindowInventory(displays: [], windows: [])
    let refreshed = WindowInventory(displays: [], windows: [
        InventoryWindow(
            key: RuntimeWindowKey(processIdentifier: 2, quartzWindowNumber: 2),
            displayID: nil,
            label: "Updated window",
            isSelectable: false,
            isSpanning: true
        )
    ])
    let provider = StatusFakeInventory(initial)
    let menuController = StatusItemMenuController(inventoryProvider: provider)
    provider.inventory = refreshed

    #expect(provider.currentInventoryCallCount == 1)
    menuController.perform(NSSelectorFromString("refreshSelected:"), with: nil)
    #expect(provider.currentInventoryCallCount == 2)
    #expect(menuController.menu.items.map(\.title).contains("⚠ Updated window — spanning, unavailable"))
}

@Test
@MainActor
func statusMenuMarksCachedInventoryStaleWithoutPerformingAnotherInventoryRead() {
    let provider = StatusFakeInventory(WindowInventory(displays: [], windows: []))
    let menuController = StatusItemMenuController(inventoryProvider: provider)

    #expect(provider.currentInventoryCallCount == 1)
    menuController.markInventoryStale()
    #expect(menuController.inventoryIsStale)
    #expect(provider.currentInventoryCallCount == 1)

    menuController.rebuildMenu()
    #expect(provider.currentInventoryCallCount == 1)
    #expect(menuController.menu.items.map(\.title).contains("Refresh Windows — window list may have changed"))

    menuController.perform(NSSelectorFromString("refreshSelected:"), with: nil)
    #expect(!menuController.inventoryIsStale)
    #expect(provider.currentInventoryCallCount == 2)
}

@Test
@MainActor
func statusMenuPatchesOnlySuccessfulMovesIntoCachedDisplayGroups() {
    let finder = RuntimeWindowKey(processIdentifier: 1, quartzWindowNumber: 41)
    let safari = RuntimeWindowKey(processIdentifier: 2, quartzWindowNumber: 52)
    let terminal = RuntimeWindowKey(processIdentifier: 3, quartzWindowNumber: 63)
    let displays = [1, 2].enumerated().map { offset, id in
        InventoryDisplay(
            snapshot: DisplaySnapshot(
                id: UInt32(id),
                frame: CGRect(x: CGFloat(offset * 100), y: 0, width: 100, height: 100),
                visibleFrame: CGRect(x: CGFloat(offset * 100), y: 0, width: 100, height: 100)
            ),
            ordinal: offset + 1,
            name: nil
        )
    }
    let provider = StatusFakeInventory(WindowInventory(
        displays: displays,
        windows: [
            InventoryWindow(key: finder, displayID: 1, label: "Finder", isSelectable: true, isSpanning: false),
            InventoryWindow(key: safari, displayID: 1, label: "Safari", isSelectable: true, isSpanning: false),
            InventoryWindow(key: terminal, displayID: 2, label: "Terminal", isSelectable: true, isSpanning: false)
        ]
    ))
    let menuController = StatusItemMenuController(inventoryProvider: provider)

    // Finder and Terminal completed the swap. Safari's failed move must stay
    // in its cached source group without requesting fresh AX inventory.
    menuController.applySuccessfulMoves([
        SuccessfulWindowMove(runtimeKey: finder, destinationDisplayID: 2),
        SuccessfulWindowMove(runtimeKey: terminal, destinationDisplayID: 1)
    ])

    #expect(provider.currentInventoryCallCount == 1)
    let titles = menuController.menu.items.map(\.title)
    let firstDisplay = titles.firstIndex(of: "Display 1")!
    let secondDisplay = titles.firstIndex(of: "Display 2")!
    #expect(titles.firstIndex(of: "        Terminal")! > firstDisplay)
    #expect(titles.firstIndex(of: "        Terminal")! < secondDisplay)
    #expect(titles.firstIndex(of: "        Safari")! > firstDisplay)
    #expect(titles.firstIndex(of: "        Safari")! < secondDisplay)
    #expect(titles.firstIndex(of: "        Finder")! > secondDisplay)
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
    var refreshCount = 0
    var staleCount = 0

    func present(from button: NSStatusBarButton?) {
        presentCount += 1
    }

    func refreshInventory() {
        refreshCount += 1
    }

    func markInventoryStale() {
        staleCount += 1
    }
}

@MainActor
private final class StatusFakeInventory: StatusItemInventoryProviding {
    var inventory: WindowInventory
    var currentInventoryCallCount = 0
    init(_ inventory: WindowInventory) { self.inventory = inventory }
    func currentInventory() -> WindowInventory {
        currentInventoryCallCount += 1
        return inventory
    }
}

@MainActor
private final class StatusFakeTerminator: ScreenSwapTerminating {
    var terminateCount = 0

    func terminate() {
        terminateCount += 1
    }
}

@Test @MainActor
func contextMenuConfiguresClickModesAndProvidesReturnAndCancel() {
    let suite = "ScreenSwapTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = ScreenSwapSettings(defaults: defaults)
    let controller = StatusItemMenuController(settings: settings)
    var changes = 0
    var pending = true
    var calls = 0
    controller.modesChanged = { changes += 1 }
    controller.swapAction = {}
    controller.moveFocusedWindowAction = {}
    controller.callReturnAction = { calls += 1 }
    controller.hasPendingReturn = { pending }
    controller.callReturnTitle = { pending ? "Return Called Window" : "Call Window to Primary Display" }
    controller.cancelCallReturnAction = { pending = false }
    controller.rebuildMenu()
    #expect(!controller.menu.autoenablesItems)
    let left = controller.menu.items.first { $0.title == "Left Click: Swap" }!
    let middle = controller.menu.items.first { $0.title == "Middle Click: Move Focused Window" }!
    #expect(left.submenu?.items.map(\.title) == InteractionMode.allCases.map(\.title))
    #expect(middle.submenu?.items[1].state == .on)
    #expect(controller.menu.items.first { $0.title == "Swap Selected Windows" }?.isEnabled == false)
    #expect(controller.menu.items.first { $0.title == "Move Focused Window to Other Display" }?.isEnabled == false)
    controller.perform(NSSelectorFromString("changeMode:"), with: middle.submenu!.items[2])
    #expect(settings.primaryMode == .swap && settings.secondaryMode == .callReturn)
    #expect(changes == 1)
    controller.perform(NSSelectorFromString("changeMode:"), with: left.submenu!.items[2])
    #expect(settings.primaryMode == .callReturn && settings.secondaryMode == .swap)
    #expect(changes == 2)
    controller.perform(NSSelectorFromString("callReturnSelected:"), with: nil)
    #expect(calls == 1)
    controller.perform(NSSelectorFromString("cancelCallReturnSelected:"), with: nil)
    #expect(!pending)
    #expect(controller.menu.items.first { $0.title == "Swap Selected Windows" }?.isEnabled == true)
    #expect(!controller.menu.items.contains { $0.title.contains("Cancel Return") })
}

@Test @MainActor
func statusItemTrackingRespondsToAppKitHoverSelectors() {
    #expect(StatusBarController.instancesRespond(to: NSSelectorFromString("mouseEntered:")))
    #expect(StatusBarController.instancesRespond(to: NSSelectorFromString("mouseExited:")))
}
