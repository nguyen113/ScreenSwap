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

    public init(terminator: any ScreenSwapTerminating = LiveScreenSwapTerminator()) {
        self.terminator = terminator
        menu = NSMenu()
        super.init()

        let exitItem = NSMenuItem(
            title: "Exit ScreenSwap",
            action: #selector(exitSelected(_:)),
            keyEquivalent: ""
        )
        exitItem.target = self
        menu.addItem(exitItem)
    }

    public func present(from button: NSStatusBarButton?) {
        guard let button else { return }
        menu.popUp(
            positioning: nil,
            at: CGPoint(x: button.bounds.midX, y: button.bounds.minY),
            in: button
        )
    }

    @objc
    public func exitSelected(_ sender: Any?) {
        terminator.terminate()
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
            tooltip = "ScreenSwap: swapped \(succeeded) of \(attempted) window(s)."
        case let .partialFailure(attempted, succeeded, failed):
            tooltip = "ScreenSwap: moved \(succeeded) of \(attempted) window(s); \(failed) failed."
        case .noMoves:
            tooltip = "ScreenSwap: no eligible windows were planned."
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
            tooltip = "ScreenSwap: swapped \(succeeded) of \(attempted) window(s)."
        case let .partialFailure(attempted, succeeded, failed):
            tooltip = "ScreenSwap: moved \(succeeded) of \(attempted) window(s); \(failed) failed."
        case .noMoves:
            tooltip = "ScreenSwap: no eligible windows were planned."
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

    public init(
        coordinator: SwapCoordinator,
        authorization: any AccessibilityAuthorizing,
        feedbackPresenter: any StatusItemFeedbackPresenting = StatusPopoverFeedbackPresenter()
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        actionHandler = StatusItemActionHandler(coordinator: coordinator, authorization: authorization)
        self.feedbackPresenter = feedbackPresenter
        clickRouter = StatusItemClickRouter(menuPresenter: StatusItemMenuController())
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await actionHandler.handleMeasuredClick(commandReceivedNanoseconds: commandReceived)
            feedbackPresenter.present(actionHandler.feedback, from: statusItem.button)
            statusItem.button?.toolTip = actionHandler.tooltip
            statusItem.button?.isEnabled = actionHandler.isEnabled
        }
    }
}

private extension StatusItemActionHandler {
    func commandReceivedNanoseconds() -> UInt64 {
        coordinator.commandReceivedNanoseconds()
    }
}
