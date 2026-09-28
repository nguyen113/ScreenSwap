import AppKit

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
                message: "ScreenSwap requires exactly two displays; found \(count)."
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

    public init(
        authorization: any AccessibilityAuthorizing,
        displays: any DisplayProviding,
        namedDisplays: (any DisplayInventoryProviding)? = nil,
        windows: any WindowInventoryProviding
    ) {
        self.authorization = authorization
        self.displays = displays
        self.namedDisplays = namedDisplays
        self.windows = windows
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
        return windows.inventory(displays: inventoryDisplays)
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
    private let shortcutRegistration: ((HotKeyShortcut) -> Bool)?

    public init(
        terminator: any ScreenSwapTerminating = LiveScreenSwapTerminator(),
        settings: ScreenSwapSettings? = nil,
        authorization: (any AccessibilityAuthorizing)? = nil,
        inventoryProvider: (any StatusItemInventoryProviding)? = nil,
        selection: WindowSelectionStore? = nil,
        shortcutRegistration: ((HotKeyShortcut) -> Bool)? = nil
    ) {
        self.terminator = terminator
        self.settings = settings
        self.authorization = authorization
        self.inventoryProvider = inventoryProvider
        self.selection = selection
        self.shortcutRegistration = shortcutRegistration
        menu = NSMenu()
        super.init()
        rebuildMenu()
    }

    public func present(from button: NSStatusBarButton?) {
        guard let button else { return }
        rebuildMenu()
        menu.popUp(
            positioning: nil,
            at: CGPoint(x: button.bounds.midX, y: button.bounds.minY),
            in: button
        )
    }

    /// Rebuilding is deliberately a read-only operation. It uses fresh menu
    /// data every time so window movement, closure, and display reassignment
    /// cannot leave a stale selection row onscreen.
    public func rebuildMenu() {
        menu.removeAllItems()
        if let inventoryProvider {
            appendInventory(inventoryProvider.currentInventory())
        }
        appendUtilityItems(separatorNeeded: !menu.items.isEmpty)
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
                title: "Selection requires exactly two displays (found \(inventory.displays.count))",
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

        for display in inventory.displays {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let children = inventory.windows(on: display.snapshot.id)
            let keys = Set(children.compactMap { $0.isSelectable ? $0.key : nil })
            let group = NSMenuItem(title: display.label, action: #selector(toggleGroup(_:)), keyEquivalent: "")
            group.target = self
            group.representedObject = SelectionMenuPayload(keys: keys)
            group.state = menuState(selection?.selectionState(for: keys) ?? .on)
            group.isEnabled = inventory.supportsSelection && !keys.isEmpty
            menu.addItem(group)
            for child in children {
                let title = child.isAutomaticallyIncluded
                    ? "    \(child.label) — included automatically"
                    : "    \(child.label)"
                let item = NSMenuItem(title: title, action: #selector(toggleWindow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = child.key.map { SelectionMenuPayload(keys: [$0]) }
                item.state = child.isAutomaticallyIncluded
                    ? .on
                    : child.key.map { menuState(selection?.selectionState(for: [$0]) ?? .on) } ?? .off
                item.isEnabled = inventory.supportsSelection && child.isSelectable && child.key != nil
                if child.isAutomaticallyIncluded {
                    item.toolTip = "Included automatically; no Quartz window identity is available for selection."
                } else if !item.isEnabled {
                    item.toolTip = "Unavailable for swapping"
                }
                menu.addItem(item)
            }
        }
    }

    private func appendUtilityItems(separatorNeeded: Bool) {
        if separatorNeeded { menu.addItem(.separator()) }
        let about = NSMenuItem(title: "About ScreenSwap", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self; menu.addItem(settingsItem)
        let exitItem = NSMenuItem(title: "Exit ScreenSwap", action: #selector(exitSelected(_:)), keyEquivalent: "")
        exitItem.target = self; menu.addItem(exitItem)
    }

    @objc private func toggleGroup(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SelectionMenuPayload,
              !payload.keys.isEmpty else { return }
        let state = selection?.selectionState(for: payload.keys) ?? .off
        selection?.setSelected(state != .on, for: payload.keys)
        rebuildMenu()
    }

    @objc private func toggleWindow(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SelectionMenuPayload,
              payload.keys.count == 1,
              let key = payload.keys.first else { return }
        selection?.setSelected(!(selection?.isSelected(key) ?? false), for: key)
        rebuildMenu()
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
                shortcutRegistration: shortcutRegistration
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
public final class StatusItemActionHandler {
    private let coordinator: SwapCoordinator
    private let authorization: any AccessibilityAuthorizing
    private var didRequestAccess = false

    public private(set) var tooltip = "ScreenSwap"
    public private(set) var isEnabled = true
    public private(set) var feedback = StatusItemFeedback(title: "ScreenSwap", message: "")
    public private(set) var diagnostics = SwapDiagnostics.empty

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
            tooltip = "ScreenSwap: requires exactly two displays (found \(count))."
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
        isEnabled = false
        defer { isEnabled = true }
        let outcome = await coordinator.swapMeasured(commandReceivedNanoseconds: commandReceivedNanoseconds).outcome
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
            tooltip = "ScreenSwap: requires exactly two displays (found \(count))."
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
    private let feedbackPresenter: any StatusItemFeedbackPresenting
    private let clickRouter: StatusItemClickRouter
    private let iconAnimation = IconAnimationController()

    public init(
        coordinator: SwapCoordinator,
        authorization: any AccessibilityAuthorizing,
        settings: ScreenSwapSettings? = nil,
        inventoryProvider: (any StatusItemInventoryProviding)? = nil,
        selection: WindowSelectionStore? = nil,
        shortcutRegistration: ((HotKeyShortcut) -> Bool)? = nil,
        feedbackPresenter: any StatusItemFeedbackPresenting = StatusPopoverFeedbackPresenter()
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        actionHandler = StatusItemActionHandler(coordinator: coordinator, authorization: authorization)
        self.feedbackPresenter = feedbackPresenter
        clickRouter = StatusItemClickRouter(menuPresenter: StatusItemMenuController(
            settings: settings,
            authorization: authorization,
            inventoryProvider: inventoryProvider,
            selection: selection,
            shortcutRegistration: shortcutRegistration
        ))
        super.init()
        configureButton()
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
        button.toolTip = actionHandler.tooltip
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
        default:
            mouseButton = .left
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

    private func performLeftClick() {
        let commandReceived = actionHandler.commandReceivedNanoseconds()
        statusItem.button?.isEnabled = false
        iconAnimation.beganSwap()
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await actionHandler.handleMeasuredClick(commandReceivedNanoseconds: commandReceived)
            feedbackPresenter.present(actionHandler.feedback, from: statusItem.button)
            statusItem.button?.toolTip = actionHandler.tooltip
            statusItem.button?.isEnabled = actionHandler.isEnabled
            iconAnimation.endedSwap()
        }
    }
}

private extension StatusItemActionHandler {
    func commandReceivedNanoseconds() -> UInt64 {
        coordinator.commandReceivedNanoseconds()
    }
}
