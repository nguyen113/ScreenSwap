import CoreGraphics
import Foundation
import ScreenSwapCore

/// Presentation state discovered through public Accessibility button attributes.
///
/// A nil state is deliberate: AX exposes zoom/full-screen controls on many
/// windows without exposing a reliable, universal current-state attribute.
/// The adapter never infers a semantic AX state from bounds, but may preserve
/// the visible-frame geometry of a zoom-capable window when that state is
/// unavailable.
public struct WindowPresentationState: Equatable, Sendable {
    public let isZoomed: Bool?
    public let isFullScreen: Bool?
    public let canToggleZoom: Bool
    public let canToggleFullScreen: Bool

    public init(
        isZoomed: Bool? = nil,
        isFullScreen: Bool? = nil,
        canToggleZoom: Bool = false,
        canToggleFullScreen: Bool = false
    ) {
        self.isZoomed = isZoomed
        self.isFullScreen = isFullScreen
        self.canToggleZoom = canToggleZoom
        self.canToggleFullScreen = canToggleFullScreen
    }

    public static let unknown = WindowPresentationState()
}

public struct PresentationTransitionPolicy: Equatable, Sendable {
    public let timeout: TimeInterval
    public let pollInterval: TimeInterval

    // Native macOS full-screen transitions create or leave a Space and can
    // legitimately take longer than a normal AX geometry update. Keep this
    // bounded, but do not classify a still-running system transition as a
    // failed move after only a half second.
    public init(timeout: TimeInterval = 3, pollInterval: TimeInterval = 0.01) {
        self.timeout = timeout
        self.pollInterval = pollInterval
    }
}

@MainActor
public protocol AccessibilityTransitionWaiting: AnyObject {
    func wait(for interval: TimeInterval)
}

@MainActor
public final class MainRunLoopAccessibilityTransitionWaiter: AccessibilityTransitionWaiting {
    public init() {}

    public func wait(for interval: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
    }
}

public struct CapturedWindow: Equatable, Sendable {
    public let snapshot: WindowSnapshot
    public let isResizable: Bool
    public let presentationState: WindowPresentationState
    /// A non-full-screen window whose AX frame fills its source display's
    /// visible frame. It must fill the destination visible frame after swap.
    public let isVisuallyMaximized: Bool
    public let runtimeKey: RuntimeWindowKey?

    public init(
        snapshot: WindowSnapshot,
        isResizable: Bool,
        presentationState: WindowPresentationState = .unknown,
        isVisuallyMaximized: Bool = false,
        runtimeKey: RuntimeWindowKey? = nil
    ) {
        self.snapshot = snapshot
        self.isResizable = isResizable
        self.presentationState = presentationState
        self.isVisuallyMaximized = isVisuallyMaximized
        self.runtimeKey = runtimeKey
    }
}

public enum WindowReadFailureKind: String, Equatable, Sendable {
    case applicationEnumeration
    case visibleWindowEnumeration
    case windowEnumeration
    case attributes
}

public struct WindowReadFailure: Equatable, Sendable {
    public let processIdentifier: Int32
    public let kind: WindowReadFailureKind

    public init(processIdentifier: Int32, kind: WindowReadFailureKind) {
        self.processIdentifier = processIdentifier
        self.kind = kind
    }
}

public struct WindowCaptureBatch: Equatable, Sendable {
    public let windows: [CapturedWindow]
    public let failures: [WindowReadFailure]
    /// Number of AX window elements considered during this capture. This includes
    /// elements excluded by the eligibility filter, but not applications whose
    /// window list could not be read.
    public let totalWindows: Int
    public let skipped: [WindowSkip]

    public init(
        windows: [CapturedWindow],
        failures: [WindowReadFailure] = [],
        totalWindows: Int? = nil,
        skipped: [WindowSkip] = []
    ) {
        self.windows = windows
        self.failures = failures
        self.totalWindows = totalWindows ?? windows.count + skipped.count
        self.skipped = skipped
    }
}

/// Non-sensitive reason a discovered AX element was not eligible for a move.
/// These values intentionally contain neither a title nor an AX identifier.
public enum WindowSkipReason: String, Codable, Equatable, Sendable {
    case nonWindow
    case minimized
    case transient
    case nonMovable
    case auxiliary
    case notVisible
    case presentationStateUnavailable
    case spanningDisplays
    case unknownSourceDisplay
    case readFailure
}

public struct WindowSkip: Equatable, Sendable {
    public let processIdentifier: Int32
    public let reason: WindowSkipReason

    public init(processIdentifier: Int32, reason: WindowSkipReason) {
        self.processIdentifier = processIdentifier
        self.reason = reason
    }
}

public enum WindowApplyFailureKind: String, Equatable, Sendable {
    case staleWindow
    case size
    case position
    case zoom
    case fullScreen
    case presentationTransition
}

public struct WindowApplyResult: Equatable, Sendable {
    public let succeeded: Bool
    public let failure: WindowApplyFailureKind?

    public init(succeeded: Bool, failure: WindowApplyFailureKind? = nil) {
        self.succeeded = succeeded
        self.failure = failure
    }

    public static let success = WindowApplyResult(succeeded: true)
}

/// Non-sensitive counts for one swap invocation. This deliberately contains
/// no window titles, document names, or Accessibility identifiers.
public struct SwapDiagnostics: Equatable, Sendable {
    public let discovered: Int
    public let eligible: Int
    /// Captured eligible windows selected for this transaction before planning.
    public let selected: Int
    public let skippedByReason: [String: Int]
    public let planned: Int
    public let attempted: Int
    public let succeeded: Int
    public let failed: Int

    public init(
        discovered: Int = 0,
        eligible: Int = 0,
        selected: Int = 0,
        skippedByReason: [String: Int] = [:],
        planned: Int = 0,
        attempted: Int = 0,
        succeeded: Int = 0,
        failed: Int = 0
    ) {
        self.discovered = discovered
        self.eligible = eligible
        self.selected = selected
        self.skippedByReason = skippedByReason
        self.planned = planned
        self.attempted = attempted
        self.succeeded = succeeded
        self.failed = failed
    }

    public static let empty = SwapDiagnostics()
}

public enum SwapOutcome: Equatable, Sendable {
    case success(attempted: Int, succeeded: Int)
    case partialFailure(attempted: Int, succeeded: Int, failed: Int)
    case noMoves
    case noSelection
    case noPermission
    case unsupportedDisplayCount(Int)
    case alreadyRunning
}

public extension SwapOutcome {
    /// Stable, non-sensitive category suitable for local diagnostic output.
    var diagnosticLabel: String {
        switch self {
        case .success:
            "success"
        case .partialFailure:
            "partialFailure"
        case .noMoves:
            "noMoves"
        case .noSelection:
            "noSelection"
        case .noPermission:
            "noPermission"
        case .unsupportedDisplayCount:
            "unsupportedDisplayCount"
        case .alreadyRunning:
            "alreadyRunning"
        }
    }
}

public protocol WindowProviding: AnyObject {
    @MainActor
    func captureWindows(displays: [DisplaySnapshot]) -> WindowCaptureBatch
}

public protocol WindowApplying: AnyObject {
    @MainActor
    func apply(move: WindowMove, isResizable: Bool) -> WindowApplyResult
}

/// Restores a captured window after a completed AX write cannot be verified
/// as visible on the active macOS Space. Handles remain transaction-local.
public protocol WindowRestoring: AnyObject {
    @MainActor
    func restore(windowID: WindowID, isResizable: Bool) -> WindowApplyResult
}

public enum WindowVerificationStatus: Equatable, Sendable {
    case verified
    case pending
    /// AX geometry matches, but Quartz no longer reports the window on screen.
    /// This is distinct from ordinary AX propagation lag so the coordinator can
    /// return the window to its captured frame after the verification deadline.
    case notVisible
    case unavailable
}

/// Reads a captured window's current AX frame after writes have completed.
/// Verification deliberately remains separate from applying so tests can model
/// delayed AX updates without issuing real Accessibility requests.
public protocol WindowVerifying: AnyObject {
    @MainActor
    func verificationStatus(for move: WindowMove, isResizable: Bool, tolerance: CGFloat) -> WindowVerificationStatus
}

@MainActor
public protocol SwapPlanning {
    func makeSwapMoves(
        windows: [WindowSnapshot],
        displayA: DisplaySnapshot,
        displayB: DisplaySnapshot
    ) -> [WindowMove]
}

extension WindowMappingEngine: SwapPlanning {}
