import AppKit
import ScreenSwapCore

public struct StatusItemFeedback: Equatable, Sendable {
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

public enum StatusItemFeedbackCatalog {
    public static func feedback(for outcome: SwapOutcome) -> StatusItemFeedback {
        switch outcome {
        case .noPermission:
            return StatusItemFeedback(
                title: "ScreenSwap",
                message: "Grant Accessibility access in System Settings, then click ScreenSwap again."
            )
        case let .unsupportedDisplayCount(count):
            return StatusItemFeedback(
                title: "ScreenSwap",
                message: "ScreenSwap requires at least two active displays; found \(count)."
            )
        case .displayTopologyChanged:
            return StatusItemFeedback(
                title: "Display configuration changed",
                message: "Your display configuration changed. Try the swap again."
            )
        case let .success(attempted, succeeded):
            return StatusItemFeedback(
                title: "ScreenSwap complete",
                message: "Swapped \(succeeded) of \(attempted) window(s)."
            )
        case let .partialFailure(attempted, succeeded, failed):
            return StatusItemFeedback(
                title: "ScreenSwap partially complete",
                message: "Moved \(succeeded) of \(attempted) window(s); \(failed) failed."
            )
        case .noMoves:
            return StatusItemFeedback(
                title: "No windows swapped",
                message: "No eligible windows were planned for this swap."
            )
        case .noSelection:
            return StatusItemFeedback(title: "No windows selected", message: "Select one or more windows from the ScreenSwap menu.")
        case .alreadyRunning:
            return StatusItemFeedback(
                title: "ScreenSwap busy",
                message: "A swap is already running."
            )
        }
    }
}

enum StatusItemMenuInventoryRefreshPolicy {
    static func shouldMarkStale(after outcome: SwapOutcome) -> Bool {
        switch outcome {
        case .success:
            return true
        case let .partialFailure(_, succeeded, _):
            return succeeded > 0
        default:
            return false
        }
    }
}

public enum StatusItemMouseButton: Equatable, Sendable {
    case left
    case right
}

public enum StatusItemInputRoute: Equatable, Sendable {
    case swap
    case menu
}

/// Keep the status item discoverable in a crowded macOS menu bar. A lone SF
/// Symbol is too easily mistaken for one of the system status icons.
public enum StatusItemAppearance {
    public static let title = "Swap"
}

/// A local command URL that is handled by the already-authorized status app.
/// This lets automation request the same swap path without granting a second
/// process Accessibility access.
public enum ScreenSwapCommandURL {
    public static let scheme = "screenswap"
    public static let swapHost = "swap"
    public static let diagnosticsHost = "diagnostics"

    public static func isSwapCommand(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme &&
            url.host?.lowercased() == swapHost &&
            (url.path.isEmpty || url.path == "/")
    }

    /// A non-mutating capture route for physical diagnostics. It runs inside
    /// the already-authorized app rather than starting a second AX process.
    public static func isDiagnosticsCommand(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme &&
            url.host?.lowercased() == diagnosticsHost &&
            (url.path.isEmpty || url.path == "/")
    }
}

@MainActor
public protocol StatusItemMenuPresenting: AnyObject {
    func present(from button: NSStatusBarButton?)
    func refreshInventory()
    func markInventoryStale()
    func applySuccessfulMoves(_ moves: [SuccessfulWindowMove])
}

public extension StatusItemMenuPresenting {
    /// Presenters without a window inventory can keep this as a no-op.
    func refreshInventory() {}
    func markInventoryStale() {}
    func applySuccessfulMoves(_ moves: [SuccessfulWindowMove]) {}
}

@MainActor
public final class StatusItemClickRouter {
    private let menuPresenter: any StatusItemMenuPresenting

    public init(menuPresenter: any StatusItemMenuPresenting) {
        self.menuPresenter = menuPresenter
    }

    @discardableResult
    public func route(
        mouseButton: StatusItemMouseButton,
        button: NSStatusBarButton?,
        leftClick: @escaping @MainActor () -> Void
    ) -> StatusItemInputRoute {
        switch mouseButton {
        case .left:
            leftClick()
            return .swap
        case .right:
            menuPresenter.present(from: button)
            return .menu
        }
    }

    public func presentMenu(from button: NSStatusBarButton?) {
        menuPresenter.present(from: button)
    }

    public func refreshMenuInventory() {
        menuPresenter.refreshInventory()
    }

    public func markMenuInventoryStale() {
        menuPresenter.markInventoryStale()
    }

    public func applySuccessfulMoves(_ moves: [SuccessfulWindowMove]) {
        menuPresenter.applySuccessfulMoves(moves)
    }
}

@MainActor
public protocol ScreenSwapTerminating: AnyObject {
    func terminate()
}

@MainActor
public protocol StatusItemInventoryProviding: AnyObject {
    func currentInventory() -> WindowInventory
}

/// Composes the read-only menu inventory without making the status UI depend
/// on AppKit display or Accessibility adapters directly.
@MainActor
public final class LiveStatusItemInventoryProvider: StatusItemInventoryProviding {
    private let authorization: any AccessibilityAuthorizing
    private let displays: any DisplayProviding
    private let namedDisplays: (any DisplayInventoryProviding)?
    private let windows: any WindowInventoryProviding
    private let displaySelection: DisplayPairSelectionStore

    public init(
        authorization: any AccessibilityAuthorizing,
        displays: any DisplayProviding,
        namedDisplays: (any DisplayInventoryProviding)? = nil,
        windows: any WindowInventoryProviding,
        displaySelection: DisplayPairSelectionStore
    ) {
        self.authorization = authorization
        self.displays = displays
        self.namedDisplays = namedDisplays
        self.windows = windows
        self.displaySelection = displaySelection
    }

    public func currentInventory() -> WindowInventory {
        guard authorization.isTrusted else { return .permissionRequired }
        let inventoryDisplays: [InventoryDisplay]
        if let namedDisplays, let result = try? namedDisplays.currentInventoryDisplays() {
            inventoryDisplays = result
        } else if let snapshots = try? displays.currentDisplays() {
            inventoryDisplays = snapshots.sorted { $0.id < $1.id }.enumerated().map {
                InventoryDisplay(snapshot: $0.element, ordinal: $0.offset + 1, name: nil)
            }
        } else {
            inventoryDisplays = []
        }
        let rawInventory = windows.inventory(displays: inventoryDisplays)
        let activeDisplays = inventoryDisplays.map(\.snapshot)
        let candidateCounts = rawInventory.windows.reduce(into: [UInt32: Int]()) { counts, window in
            guard let displayID = window.displayID,
                  !window.isSpanning,
                  window.isSelectable || window.isAutomaticallyIncluded else { return }
            counts[displayID, default: 0] += 1
        }
        let primaryDisplayID = (displays as? any PrimaryDisplayProviding)?.primaryDisplayID()
            ?? activeDisplays.map(\.id).min()
        if let primaryDisplayID {
            displaySelection.reconcile(
                activeDisplays: activeDisplays,
                primaryDisplayID: primaryDisplayID,
                candidateCounts: candidateCounts
            )
        }
        return WindowInventory(
            displays: inventoryDisplays,
            windows: rawInventory.windows,
            selectedDisplayIDs: displaySelection.selectedDisplayIDs,
            primaryDisplayID: primaryDisplayID
        )
    }
}

@MainActor
public final class LiveScreenSwapTerminator: ScreenSwapTerminating {
    public init() {}

    public func terminate() {
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
public final class StatusItemMenuController: NSObject, StatusItemMenuPresenting {
    public let menu: NSMenu
    private let terminator: any ScreenSwapTerminating
    private let settings: ScreenSwapSettings?
    private let authorization: (any AccessibilityAuthorizing)?
    private let inventoryProvider: (any StatusItemInventoryProviding)?
    private let selection: WindowSelectionStore?
    private let displaySelection: DisplayPairSelectionStore?
    private let shortcutRegistration: ((HotKeyShortcut) -> Bool)?
    private let moveShortcutRegistration: ((HotKeyShortcut) -> Bool)?
    public var moveFocusedWindowAction: (() -> Void)?
    /// Inventory collection crosses process boundaries through Accessibility.
    /// Keep that work out of menu presentation and checkbox actions so the
    /// status menu stays responsive even when another app responds slowly.
    private var cachedInventory: WindowInventory?
    public private(set) var inventoryIsStale = false

    public init(
        terminator: any ScreenSwapTerminating = LiveScreenSwapTerminator(),
        settings: ScreenSwapSettings? = nil,
        authorization: (any AccessibilityAuthorizing)? = nil,
        inventoryProvider: (any StatusItemInventoryProviding)? = nil,
        selection: WindowSelectionStore? = nil,
        displaySelection: DisplayPairSelectionStore? = nil,
        shortcutRegistration: ((HotKeyShortcut) -> Bool)? = nil,
        moveShortcutRegistration: ((HotKeyShortcut) -> Bool)? = nil
    ) {
        self.terminator = terminator
        self.settings = settings
        self.authorization = authorization
        self.inventoryProvider = inventoryProvider
        self.selection = selection
        self.displaySelection = displaySelection
        self.shortcutRegistration = shortcutRegistration
        self.moveShortcutRegistration = moveShortcutRegistration
        menu = NSMenu()
        super.init()
        refreshInventory()
    }

    public func present(from button: NSStatusBarButton?) {
        guard let button else { return }
        rebuildMenu()
        // Anchor the first row directly below the status item. Leaving the
        // positioning item nil lets AppKit choose a row and can move the menu
        // upward beneath the menu bar, obscuring the first control.
        menu.popUp(
            positioning: menu.items.first,
            at: CGPoint(x: button.bounds.midX, y: button.bounds.minY),
            in: button
        )
    }

    /// Collects a new inventory for a future menu presentation. This is kept
    /// explicit because it can perform slow Accessibility reads.
    public func refreshInventory() {
        cachedInventory = inventoryProvider?.currentInventory()
        inventoryIsStale = false
        rebuildMenu()
    }

    /// Records that a swap changed the visible desktop. The next menu stays
    /// immediate and offers an explicit refresh instead of doing AX discovery
    /// on the swap completion path.
    public func markInventoryStale() {
        guard inventoryProvider != nil else { return }
        inventoryIsStale = true
    }

    /// Patches known transaction results directly into the current snapshot.
    /// This is pure in-memory work and never calls the inventory provider.
    public func applySuccessfulMoves(_ moves: [SuccessfulWindowMove]) {
        guard !moves.isEmpty, let cachedInventory else { return }
        let destinations = moves.reduce(into: [RuntimeWindowKey: UInt32]()) { result, move in
            result[move.runtimeKey] = move.destinationDisplayID
        }
        let updatedWindows = cachedInventory.windows.map { window in
            guard let key = window.key, let destination = destinations[key] else { return window }
            return InventoryWindow(
                key: key,
                displayID: destination,
                label: window.label,
                isSelectable: window.isSelectable,
                isAutomaticallyIncluded: window.isAutomaticallyIncluded,
                isNativeFullScreenUnsupported: window.isNativeFullScreenUnsupported,
                isSpanning: window.isSpanning
            )
        }
        self.cachedInventory = WindowInventory(
            displays: cachedInventory.displays,
            windows: updatedWindows,
            isAuthorized: cachedInventory.isAuthorized,
            selectedDisplayIDs: cachedInventory.selectedDisplayIDs,
            primaryDisplayID: cachedInventory.primaryDisplayID
        )
        rebuildMenu()
    }

    /// Rebuilding only renders the cached snapshot. It must remain free of
    /// inventory discovery: this is called for right-click presentation and
    /// every selection change.
    public func rebuildMenu() {
        menu.removeAllItems()
        if let cachedInventory {
            appendInventory(inventoryForCurrentDisplaySelection(cachedInventory))
        }
        if inventoryProvider != nil {
            appendRefreshItem(separatorNeeded: !menu.items.isEmpty)
        }
        appendUtilityItems(separatorNeeded: !menu.items.isEmpty)
    }

    private func inventoryForCurrentDisplaySelection(_ inventory: WindowInventory) -> WindowInventory {
        guard let displaySelection else { return inventory }
        return WindowInventory(
            displays: inventory.displays,
            windows: inventory.windows,
            isAuthorized: inventory.isAuthorized,
            selectedDisplayIDs: Set(displaySelection.frozenPair()),
            primaryDisplayID: inventory.primaryDisplayID
        )
    }

    private func appendInventory(_ inventory: WindowInventory) {
        guard inventory.isAuthorized else {
            let item = NSMenuItem(title: "Accessibility permission required", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let selectableKeys = Set(inventory.windows.compactMap { $0.isSelectable ? $0.key : nil })
        selection?.reconcile(selectableKeys)
        if !inventory.supportsSelection {
            let item = NSMenuItem(
                title: "Swap requires at least two active displays (found \(inventory.displays.count))",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }

        let spanning = inventory.spanningWindows
        if !spanning.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let heading = NSMenuItem(title: "Spanning windows — unavailable", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            heading.toolTip = "Spanning windows cannot be swapped"
            menu.addItem(heading)
            for window in spanning {
                let item = NSMenuItem(title: "⚠ \(window.label) — spanning, unavailable", action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.state = .off
                item.toolTip = "Spanning window — unavailable"
                item.attributedTitle = NSAttributedString(
                    string: item.title,
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
                menu.addItem(item)
            }
        }

        let activeDisplays = inventory.displays.map(\.snapshot)
        let candidateCounts = inventory.windows.reduce(into: [UInt32: Int]()) { counts, window in
            guard let displayID = window.displayID,
                  !window.isSpanning,
                  window.isSelectable || window.isAutomaticallyIncluded else { return }
            counts[displayID, default: 0] += 1
        }
        let primaryDisplayID = inventory.primaryDisplayID ?? activeDisplays.map(\.id).min() ?? 0
        for display in inventory.displays {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let children = inventory.windows(on: display.snapshot.id)
            let keys = Set(children.compactMap { $0.isSelectable ? $0.key : nil })
            let isSelectedDisplay = inventory.isDisplaySelected(display.snapshot.id)
            let displayItem = NSMenuItem(title: display.label, action: #selector(toggleDisplay(_:)), keyEquivalent: "")
            displayItem.target = self
            displayItem.representedObject = DisplaySelectionMenuPayload(
                displayID: display.snapshot.id,
                activeDisplays: activeDisplays,
                primaryDisplayID: primaryDisplayID,
                candidateCounts: candidateCounts
            )
            displayItem.state = isSelectedDisplay ? .on : .off
            // Pair membership cannot be reduced to one. Choose an unchecked
            // display to replace a pair member instead.
            displayItem.isEnabled = inventory.displays.count > 2 && !isSelectedDisplay
            if isSelectedDisplay && inventory.displays.count > 2 {
                displayItem.toolTip = "Choose another display to replace this member of the swap pair."
            }
            menu.addItem(displayItem)

            let group = NSMenuItem(title: "    All windows", action: #selector(toggleGroup(_:)), keyEquivalent: "")
            group.target = self
            group.representedObject = SelectionMenuPayload(keys: keys)
            group.state = menuState(selection?.selectionState(for: keys) ?? .on)
            group.isEnabled = inventory.supportsSelection && isSelectedDisplay && !keys.isEmpty
            if !isSelectedDisplay { group.toolTip = "Select this display to change its windows." }
            menu.addItem(group)
            for child in children {
                let title = child.isNativeFullScreenUnsupported
                    ? "        \(child.label) — native full-screen, unsupported"
                    : child.isAutomaticallyIncluded
                    ? "        \(child.label) — included automatically"
                    : "        \(child.label)"
                let item = NSMenuItem(title: title, action: #selector(toggleWindow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = child.key.map { SelectionMenuPayload(keys: [$0]) }
                item.state = child.isAutomaticallyIncluded && isSelectedDisplay
                    ? .on
                    : child.key.map { menuState(selection?.selectionState(for: [$0]) ?? .on) } ?? .off
                item.isEnabled = inventory.supportsSelection && isSelectedDisplay && child.isSelectable && child.key != nil
                if child.isNativeFullScreenUnsupported {
                    item.toolTip = "Native macOS full-screen Spaces cannot be swapped safely in this version. Exit full screen first to include this window."
                } else if child.isAutomaticallyIncluded && isSelectedDisplay {
                    item.toolTip = "Included automatically; no Quartz window identity is available for selection."
                } else if child.isAutomaticallyIncluded {
                    item.toolTip = "Select this display to include this native full-screen window."
                } else if !item.isEnabled {
                    item.toolTip = "Unavailable for swapping"
                }
                menu.addItem(item)
            }
        }
    }

    private func appendUtilityItems(separatorNeeded: Bool) {
        if separatorNeeded { menu.addItem(.separator()) }
        if moveFocusedWindowAction != nil {
            let move = NSMenuItem(title: "Move Focused Window to Other Display", action: #selector(moveFocusedWindowSelected(_:)), keyEquivalent: "")
            move.target = self
            move.toolTip = "Middle-click the ScreenSwap icon or use the configured shortcut."
            menu.addItem(move)
            menu.addItem(.separator())
        }
        let about = NSMenuItem(title: "About ScreenSwap", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self; menu.addItem(settingsItem)
        let exitItem = NSMenuItem(title: "Exit ScreenSwap", action: #selector(exitSelected(_:)), keyEquivalent: "")
        exitItem.target = self; menu.addItem(exitItem)
    }

    private func appendRefreshItem(separatorNeeded: Bool) {
        if separatorNeeded { menu.addItem(.separator()) }
        let title = inventoryIsStale
            ? "Refresh Windows — window list may have changed"
            : "Refresh Windows"
        let refresh = NSMenuItem(title: title, action: #selector(refreshSelected(_:)), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
    }

    @objc private func toggleGroup(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SelectionMenuPayload,
              !payload.keys.isEmpty else { return }
        let state = selection?.selectionState(for: payload.keys) ?? .off
        selection?.setSelected(state != .on, for: payload.keys)
        rebuildMenu()
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? DisplaySelectionMenuPayload else { return }
        displaySelection?.select(
            displayID: payload.displayID,
            activeDisplays: payload.activeDisplays,
            primaryDisplayID: payload.primaryDisplayID,
            candidateCounts: payload.candidateCounts
        )
        rebuildMenu()
    }

    @objc private func toggleWindow(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SelectionMenuPayload,
              payload.keys.count == 1,
              let key = payload.keys.first else { return }
        selection?.setSelected(!(selection?.isSelected(key) ?? false), for: key)
        rebuildMenu()
    }

    @objc private func refreshSelected(_ sender: Any?) {
        refreshInventory()
    }

    @objc private func moveFocusedWindowSelected(_ sender: Any?) {
        moveFocusedWindowAction?()
    }

    private func menuState(_ state: WindowSelectionState) -> NSControl.StateValue {
        switch state {
        case .off: return .off
        case .on: return .on
        case .mixed: return .mixed
        }
    }

    @objc
    public func exitSelected(_ sender: Any?) {
        terminator.terminate()
    }

    @objc private func showAbout(_ sender: Any?) { AboutWindowController.shared.present() }
    @objc private func showSettings(_ sender: Any?) {
        if let settings, let authorization {
            SettingsWindowController.show(
                settings: settings,
                authorization: authorization,
                shortcutRegistration: shortcutRegistration,
                moveShortcutRegistration: moveShortcutRegistration
            )
        }
    }
}

@MainActor
private final class SelectionMenuPayload: NSObject {
    let keys: Set<RuntimeWindowKey>
    init(keys: Set<RuntimeWindowKey>) { self.keys = keys }
}

@MainActor
private final class DisplaySelectionMenuPayload: NSObject {
    let displayID: UInt32
    let activeDisplays: [DisplaySnapshot]
    let primaryDisplayID: UInt32
    let candidateCounts: [UInt32: Int]

    init(
        displayID: UInt32,
        activeDisplays: [DisplaySnapshot],
        primaryDisplayID: UInt32,
        candidateCounts: [UInt32: Int]
    ) {
        self.displayID = displayID
        self.activeDisplays = activeDisplays
        self.primaryDisplayID = primaryDisplayID
        self.candidateCounts = candidateCounts
    }
}

@MainActor
public final class StatusItemActionHandler {
    private let coordinator: SwapCoordinator
    private let authorization: any AccessibilityAuthorizing
    private var didRequestAccess = false

    public private(set) var tooltip = "ScreenSwap"
    public private(set) var isEnabled = true
    public private(set) var feedback = StatusItemFeedback(title: "ScreenSwap", message: "")
    public private(set) var diagnostics = SwapDiagnostics.empty
    public var latestSuccessfulWindowMoves: [SuccessfulWindowMove] {
        coordinator.latestSuccessfulWindowMoves
    }

    public init(coordinator: SwapCoordinator, authorization: any AccessibilityAuthorizing) {
        self.coordinator = coordinator
        self.authorization = authorization
    }

    @discardableResult
    public func handleClick() -> SwapOutcome {
        isEnabled = false
        defer { isEnabled = true }
        let outcome = coordinator.swap()
        diagnostics = coordinator.lastDiagnostics
        feedback = StatusItemFeedbackCatalog.feedback(for: outcome)
        switch outcome {
        case .noPermission:
            if !didRequestAccess {
                didRequestAccess = true
                authorization.requestAccess()
            }
            tooltip = "ScreenSwap: grant Accessibility access, then click again."
        case let .unsupportedDisplayCount(count):
            tooltip = "ScreenSwap: requires at least two active displays (found \(count))."
        case .displayTopologyChanged:
            tooltip = "ScreenSwap: display configuration changed. Try again."
        case let .success(attempted, succeeded):
            tooltip = "ScreenSwap: selected \(diagnostics.selected), attempted \(attempted), succeeded \(succeeded), failed 0."
        case let .partialFailure(attempted, succeeded, failed):
            tooltip = "ScreenSwap: selected \(diagnostics.selected), attempted \(attempted), succeeded \(succeeded), failed \(failed)."
        case .noMoves:
            tooltip = "ScreenSwap: no eligible windows were planned."
        case .noSelection:
            tooltip = "ScreenSwap: no selection — selected 0, attempted 0, succeeded 0, failed 0."
        case .alreadyRunning:
            tooltip = "ScreenSwap: a swap is already running."
        }
        return outcome
    }

    /// The status item calls this path in production. It keeps T0 at the
    /// click handler, while allowing AX frame verification to poll without
    /// blocking the AppKit event loop.
    public func handleMeasuredClick(commandReceivedNanoseconds: UInt64) async -> SwapOutcome {
        await handleMeasured(commandReceivedNanoseconds: commandReceivedNanoseconds, focusedWindowKey: nil)
    }

    public func handleMeasuredMove(
        _ key: RuntimeWindowKey,
        commandReceivedNanoseconds: UInt64
    ) async -> SwapOutcome {
        await handleMeasured(commandReceivedNanoseconds: commandReceivedNanoseconds, focusedWindowKey: key)
    }

    private func handleMeasured(commandReceivedNanoseconds: UInt64, focusedWindowKey: RuntimeWindowKey?) async -> SwapOutcome {
        isEnabled = false
        defer { isEnabled = true }
        let outcome: SwapOutcome
        if let focusedWindowKey {
            outcome = await coordinator.moveFocusedWindowMeasured(
                focusedWindowKey, commandReceivedNanoseconds: commandReceivedNanoseconds
            ).outcome
        } else {
            outcome = await coordinator.swapMeasured(commandReceivedNanoseconds: commandReceivedNanoseconds).outcome
        }
        diagnostics = coordinator.lastDiagnostics
        feedback = StatusItemFeedbackCatalog.feedback(for: outcome)
        if focusedWindowKey != nil {
            switch outcome {
            case .success:
                feedback = StatusItemFeedback(title: "Window moved", message: "Moved to the other selected display.")
            case .noMoves:
                feedback = StatusItemFeedback(title: "Window not moved", message: "The focused window is unavailable on the selected display pair.")
            default:
                break
            }
        }
        switch outcome {
        case .noPermission:
            if !didRequestAccess {
                didRequestAccess = true
                authorization.requestAccess()
            }
            tooltip = "ScreenSwap: grant Accessibility access, then click again."
        case let .unsupportedDisplayCount(count):
            tooltip = "ScreenSwap: requires at least two active displays (found \(count))."
        case .displayTopologyChanged:
            tooltip = "ScreenSwap: display configuration changed. Try again."
        case let .success(attempted, succeeded):
            tooltip = "ScreenSwap: selected \(diagnostics.selected), attempted \(attempted), succeeded \(succeeded), failed 0."
        case let .partialFailure(attempted, succeeded, failed):
            tooltip = "ScreenSwap: selected \(diagnostics.selected), attempted \(attempted), succeeded \(succeeded), failed \(failed)."
        case .noMoves:
            tooltip = "ScreenSwap: no eligible windows were planned."
        case .noSelection:
            tooltip = "ScreenSwap: no selection — selected 0, attempted 0, succeeded 0, failed 0."
        case .alreadyRunning:
            tooltip = "ScreenSwap: a swap is already running."
        }
        return outcome
    }
}

@MainActor
public protocol StatusItemFeedbackPresenting: AnyObject {
    func present(_ feedback: StatusItemFeedback, from button: NSStatusBarButton?)
}

/// Presents click results immediately without changing the status item's icon,
/// placement, or enabled appearance.
@MainActor
public final class StatusPopoverFeedbackPresenter: NSObject, StatusItemFeedbackPresenting {
    /// Feedback is transient confirmation, not a persistent status surface.
    public static let autoDismissInterval: TimeInterval = 1.5
    private var popover: NSPopover?
    private var pendingDismissal: DispatchWorkItem?

    public override init() {
        super.init()
    }

    public func present(_ feedback: StatusItemFeedback, from button: NSStatusBarButton?) {
        guard let button else { return }
        pendingDismissal?.cancel()
        popover?.performClose(nil)

        let nextPopover = NSPopover()
        nextPopover.behavior = .transient
        nextPopover.animates = false
        nextPopover.contentViewController = StatusFeedbackViewController(feedback: feedback)
        nextPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = nextPopover

        let dismissal = DispatchWorkItem { [weak self, weak nextPopover] in
            guard let self, let nextPopover, self.popover === nextPopover else { return }
            nextPopover.performClose(nil)
            self.popover = nil
        }
        pendingDismissal = dismissal
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.autoDismissInterval,
            execute: dismissal
        )
    }
}

@MainActor
private final class StatusFeedbackViewController: NSViewController {
    private let feedback: StatusItemFeedback

    init(feedback: StatusItemFeedback) {
        self.feedback = feedback
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let titleLabel = NSTextField(labelWithString: feedback.title)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.alignment = .left

        let messageLabel = NSTextField(wrappingLabelWithString: feedback.message)
        messageLabel.alignment = .left

        let stack = NSStackView(views: [titleLabel, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 68))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        view = container
    }
}

@MainActor
public final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let actionHandler: StatusItemActionHandler
    private let authorization: any AccessibilityAuthorizing
    private let focusedWindowProvider: any FocusedWindowProviding
    private let feedbackPresenter: any StatusItemFeedbackPresenting
    private let menuController: StatusItemMenuController
    private let clickRouter: StatusItemClickRouter
    private let iconAnimation = IconAnimationController()
    private var menuFocusedWindowKey: RuntimeWindowKey?
    private var middleClickMonitor: MiddleClickMonitor?

    public init(
        coordinator: SwapCoordinator,
        authorization: any AccessibilityAuthorizing,
        settings: ScreenSwapSettings? = nil,
        inventoryProvider: (any StatusItemInventoryProviding)? = nil,
        selection: WindowSelectionStore? = nil,
        displaySelection: DisplayPairSelectionStore? = nil,
        shortcutRegistration: ((HotKeyShortcut) -> Bool)? = nil,
        moveShortcutRegistration: ((HotKeyShortcut) -> Bool)? = nil,
        focusedWindowProvider: (any FocusedWindowProviding)? = nil,
        feedbackPresenter: any StatusItemFeedbackPresenting = StatusPopoverFeedbackPresenter()
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        actionHandler = StatusItemActionHandler(coordinator: coordinator, authorization: authorization)
        self.authorization = authorization
        self.focusedWindowProvider = focusedWindowProvider ?? LiveFocusedWindowProvider(authorization: authorization)
        self.feedbackPresenter = feedbackPresenter
        menuController = StatusItemMenuController(
            settings: settings,
            authorization: authorization,
            inventoryProvider: inventoryProvider,
            selection: selection,
            displaySelection: displaySelection,
            shortcutRegistration: shortcutRegistration,
            moveShortcutRegistration: moveShortcutRegistration
        )
        clickRouter = StatusItemClickRouter(menuPresenter: menuController)
        super.init()
        menuController.moveFocusedWindowAction = { [weak self] in self?.moveMenuFocusedWindow() }
        configureButton()
        middleClickMonitor = MiddleClickMonitor(
            iconFrame: { [weak self] in self?.quartzButtonFrame() },
            focusedWindowKey: { [weak self] in self?.focusedWindowProvider.focusedWindowKey() },
            onClick: { [weak self] key in self?.performMove(key: key) }
        )
        middleClickMonitor?.start()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "arrow.left.arrow.right",
            accessibilityDescription: "Swap windows between displays"
        )
        button.image?.isTemplate = true
        button.title = StatusItemAppearance.title
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = buttonToolTip
        button.addTrackingArea(NSTrackingArea(rect: button.bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    @objc public func mouseEntered(with event: NSEvent) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shouldAnimate = iconAnimation.pointerEntered(reduceMotion: reduced)
        guard let button = statusItem.button else { return }
        if reduced {
            button.contentTintColor = .secondaryLabelColor
            return
        }
        guard shouldAnimate else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            button.animator().alphaValue = 0.55
        } completionHandler: { [weak button] in
            Task { @MainActor in button?.alphaValue = 1 }
        }
    }

    @objc public func mouseExited(with event: NSEvent) {
        iconAnimation.pointerExited()
        statusItem.button?.alphaValue = 1
        statusItem.button?.contentTintColor = nil
    }

    @objc
    private func statusItemClicked() {
        let mouseButton: StatusItemMouseButton
        switch NSApp.currentEvent?.type {
        case .rightMouseDown, .rightMouseUp:
            mouseButton = .right
        case .otherMouseDown, .otherMouseUp:
            return
        default:
            mouseButton = .left
        }
        if mouseButton == .right {
            menuFocusedWindowKey = focusedWindowProvider.focusedWindowKey()
        }
        clickRouter.route(mouseButton: mouseButton, button: statusItem.button) { [weak self] in
            self?.performLeftClick()
        }
    }

    /// Invokes exactly the same measured swap action as a left status-item
    /// click. This is intentionally public to the app delegate's command URL
    /// handler, not a second Accessibility client.
    public func triggerSwap() {
        performLeftClick()
    }

    public func triggerMoveFocusedWindow() {
        performMove(key: focusedWindowProvider.focusedWindowKey())
    }

    private func moveMenuFocusedWindow() {
        performMove(key: menuFocusedWindowKey)
        menuFocusedWindowKey = nil
    }

    private func quartzButtonFrame() -> CGRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let appKitFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return AppKitCoordinateConverter(mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
            .quartzRect(from: appKitFrame)
    }

    private var buttonToolTip: String {
        actionHandler.tooltip + "\nMiddle-click to move the focused window."
    }

    private func performMove(key: RuntimeWindowKey?) {
        guard authorization.isTrusted else {
            authorization.requestAccess()
            feedbackPresenter.present(StatusItemFeedbackCatalog.feedback(for: .noPermission), from: statusItem.button)
            return
        }
        guard let key else {
            feedbackPresenter.present(
                StatusItemFeedback(title: "No focused window", message: "Focus a movable window and try again."),
                from: statusItem.button
            )
            return
        }
        let commandReceived = actionHandler.commandReceivedNanoseconds()
        statusItem.button?.isEnabled = false
        iconAnimation.beganSwap()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await actionHandler.handleMeasuredMove(key, commandReceivedNanoseconds: commandReceived)
            feedbackPresenter.present(actionHandler.feedback, from: statusItem.button)
            statusItem.button?.toolTip = buttonToolTip
            statusItem.button?.isEnabled = actionHandler.isEnabled
            iconAnimation.endedSwap()
            if StatusItemMenuInventoryRefreshPolicy.shouldMarkStale(after: outcome) {
                clickRouter.applySuccessfulMoves(actionHandler.latestSuccessfulWindowMoves)
                clickRouter.markMenuInventoryStale()
            }
        }
    }

    private func performLeftClick() {
        let commandReceived = actionHandler.commandReceivedNanoseconds()
        statusItem.button?.isEnabled = false
        iconAnimation.beganSwap()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await actionHandler.handleMeasuredClick(commandReceivedNanoseconds: commandReceived)
            feedbackPresenter.present(actionHandler.feedback, from: statusItem.button)
            statusItem.button?.toolTip = buttonToolTip
            statusItem.button?.isEnabled = actionHandler.isEnabled
            iconAnimation.endedSwap()
            if StatusItemMenuInventoryRefreshPolicy.shouldMarkStale(after: outcome) {
                // Do not perform a synchronous AX inventory crawl after a
                // swap. It would block the main actor just as the UI becomes
                // interactive again.
                clickRouter.applySuccessfulMoves(actionHandler.latestSuccessfulWindowMoves)
                clickRouter.markMenuInventoryStale()
            }
            if case .unsupportedDisplayCount = outcome {
                clickRouter.presentMenu(from: statusItem.button)
            }
        }
    }
}

private extension StatusItemActionHandler {
    func commandReceivedNanoseconds() -> UInt64 {
        coordinator.commandReceivedNanoseconds()
    }
}
