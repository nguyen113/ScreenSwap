import CoreGraphics
import Foundation
import os
import ScreenSwapCore

@MainActor
public final class AccessibilityWindowService: WindowProviding, WindowApplying, WindowRestoring, WindowVerifying, WindowInventoryProviding {
    private static let diagnosticLogger = Logger(subsystem: "com.screenswap.app", category: "diagnostics")
    private let client: any AccessibilityClient
    /// Inventory discovery owns a separate client cache so opening the menu
    /// cannot invalidate AX handles retained by an in-flight swap transaction.
    private let inventoryClient: (any AccessibilityClient)?
    private let processIdentifier: Int32
    private let mapping = WindowMappingEngine()
    private var lookup: [WindowID: AccessibilityWindowHandle] = [:]
    private var presentationStates: [WindowID: WindowPresentationState] = [:]
    private var visuallyMaximizedWindowIDs: Set<WindowID> = []
    /// Quartz window numbers are opaque and contain no titles or document
    /// content. Retain only the current capture's maximized windows so a
    /// resize across unequal displays can round-trip without losing intent.
    private var maximizedWindowNumbers: Set<UInt32> = []
    private var displaysByID: [UInt32: DisplaySnapshot] = [:]
    private var sourceFrames: [WindowID: CGRect] = [:]
    private var sourceDisplayIDs: [WindowID: UInt32] = [:]
    private var diagnosticWindowOrdinals: [WindowID: Int] = [:]
    /// The diagnostics URL enables this only for the lifetime of the installed
    /// app process. It keeps release builds quiet during ordinary menu-bar use.
    private var localDiagnosticsEnabled = false
    private let transitionPolicy: PresentationTransitionPolicy
    private let transitionWaiter: any AccessibilityTransitionWaiting

    public init(
        client: any AccessibilityClient,
        inventoryClient: (any AccessibilityClient)? = nil,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        transitionPolicy: PresentationTransitionPolicy = PresentationTransitionPolicy(),
        transitionWaiter: any AccessibilityTransitionWaiting = MainRunLoopAccessibilityTransitionWaiter()
    ) {
        self.client = client
        self.inventoryClient = inventoryClient
        self.processIdentifier = processIdentifier
        self.transitionPolicy = transitionPolicy
        self.transitionWaiter = transitionWaiter
    }

    /// Enables non-sensitive capture/apply diagnostics for this app process.
    /// This is deliberately reached through the already-authorized app's
    /// `screenswap://diagnostics` route rather than a second AX process.
    public func enableDiagnostics() {
        localDiagnosticsEnabled = true
    }

    /// Builds presentation-only menu data. It deliberately does not touch the
    /// transaction lookup, source frames, presentation state, or AX geometry.
    public func inventory(displays: [InventoryDisplay]) -> WindowInventory {
        let snapshots = displays.map(\.snapshot)
        guard !snapshots.isEmpty else {
            return WindowInventory(displays: displays, windows: [])
        }
        let reader = inventoryClient ?? client
        reader.beginCapture()
        guard let applications = try? reader.applications(),
              let visibleWindows = try? reader.visibleWindows() else {
            return WindowInventory(displays: displays, windows: [])
        }

        var windows: [InventoryWindow] = []
        var ordinal = 0
        var unmatchedVisibleWindows = visibleWindows
        for application in applications where application.processIdentifier != processIdentifier && !application.isTerminated {
            guard !isAuxiliaryApplication(application),
                  let handles = try? reader.windows(for: application) else { continue }
            for handle in handles {
                guard let attributes = try? reader.attributes(for: handle),
                      attributes.role == "AXWindow",
                      !isTransient(attributes) else { continue }
                let frame = CGRect(origin: attributes.position, size: attributes.size)
                guard !frame.isEmpty else { continue }
                let isSpanning = WindowInventoryClassifier.spans(frame, displays: snapshots)
                let displayID = WindowInventoryClassifier.owner(of: frame, displays: snapshots)
                guard isSpanning || displayID != nil else { continue }
                ordinal += 1
                let visibleIndex = VisibleWindowMatcher.matchIndex(
                    processIdentifier: application.processIdentifier,
                    frame: frame,
                    candidates: unmatchedVisibleWindows
                )
                let visible = visibleIndex.map { unmatchedVisibleWindows.remove(at: $0) }
                let key = visible.flatMap { visibleWindow in
                    visibleWindow.windowNumber.map {
                        RuntimeWindowKey(processIdentifier: application.processIdentifier, quartzWindowNumber: $0)
                    }
                }
                let isEligible = {
                    if case .eligible = WindowClassifier.classify(attributes) { return true }
                    return false
                }()
                // Quartz can omit native full-screen windows in a different
                // Space. That is the only AX-only window form capture admits,
                // so only it may be shown as included automatically.
                let isAutomaticallyIncluded = !isSpanning && isEligible &&
                    key == nil && attributes.presentationState.isFullScreen == true
                windows.append(InventoryWindow(
                    key: key,
                    displayID: displayID,
                    label: WindowInventoryClassifier.label(
                        applicationName: application.localizedName,
                        title: try? reader.title(for: handle),
                        ordinal: ordinal
                    ),
                    isSelectable: !isSpanning && isEligible && key != nil,
                    isAutomaticallyIncluded: isAutomaticallyIncluded,
                    isSpanning: isSpanning
                ))
            }
        }
        return WindowInventory(displays: displays, windows: windows)
    }

    private func isTransient(_ attributes: AccessibilityWindowAttributes) -> Bool {
        guard attributes.role == "AXWindow" else { return true }
        let transientSubroles: Set<String> = [
            "AXDialog", "AXSystemDialog", "AXSheet", "AXFloatingWindow", "AXPopover",
            "AXSystemFloatingWindow", "AXUnknown", "AXUtilityWindow", "AXDesktopWidget",
            "AXWidget", "AXDesktop", "AXDockWindow", "AXMenu", "AXHelpTag"
        ]
        return transientSubroles.contains(attributes.subrole ?? "")
    }

    public func captureWindows(displays: [DisplaySnapshot]) -> WindowCaptureBatch {
        guard displays.count == 2 else {
            lookup = [:]
            presentationStates = [:]
            visuallyMaximizedWindowIDs = []
            maximizedWindowNumbers = []
            displaysByID = [:]
            sourceFrames = [:]
            sourceDisplayIDs = [:]
            return WindowCaptureBatch(windows: [])
        }
        let displayA = displays[0]
        let displayB = displays[1]
        var captured: [CapturedWindow] = []
        var failures: [WindowReadFailure] = []
        var skipped: [WindowSkip] = []
        var totalWindows = 0
        var nextLookup: [WindowID: AccessibilityWindowHandle] = [:]
        var nextPresentationStates: [WindowID: WindowPresentationState] = [:]
        var nextSourceFrames: [WindowID: CGRect] = [:]
        var nextVisuallyMaximizedWindowIDs: Set<WindowID> = []
        var nextMaximizedWindowNumbers: Set<UInt32> = []
        var geometryMaximizedCount = 0
        var retainedMaximizedCount = 0
        var knownZoomedCount = 0
        var unknownZoomStateCount = 0
        var candidateOrdinal = 0

        let applications: [AccessibilityApplication]
        do {
            applications = try client.applications()
        } catch {
            lookup = [:]
            presentationStates = [:]
            visuallyMaximizedWindowIDs = []
            maximizedWindowNumbers = []
            displaysByID = [:]
            sourceFrames = [:]
            sourceDisplayIDs = [:]
            return WindowCaptureBatch(
                windows: [],
                failures: [WindowReadFailure(processIdentifier: processIdentifier, kind: .applicationEnumeration)]
            )
        }

        let visibleWindows: [VisibleWindowSnapshot]
        do {
            visibleWindows = try client.visibleWindows()
        } catch {
            lookup = [:]
            presentationStates = [:]
            visuallyMaximizedWindowIDs = []
            maximizedWindowNumbers = []
            displaysByID = [:]
            sourceFrames = [:]
            sourceDisplayIDs = [:]
            client.beginCapture()
            return WindowCaptureBatch(
                windows: [],
                failures: [WindowReadFailure(processIdentifier: processIdentifier, kind: .visibleWindowEnumeration)]
            )
        }

        client.beginCapture()
        var unmatchedVisibleWindows = visibleWindows

        for application in applications where application.processIdentifier != processIdentifier && !application.isTerminated {
            let handles: [AccessibilityWindowHandle]
            do {
                handles = try client.windows(for: application)
            } catch {
                failures.append(WindowReadFailure(processIdentifier: application.processIdentifier, kind: .windowEnumeration))
                continue
            }

            if isAuxiliaryApplication(application) {
                skipped.append(contentsOf: handles.map { _ in
                    WindowSkip(processIdentifier: application.processIdentifier, reason: .auxiliary)
                })
                totalWindows += handles.count
                continue
            }

            for handle in handles {
                totalWindows += 1
                candidateOrdinal += 1
                let attributes: AccessibilityWindowAttributes
                do {
                    attributes = try client.attributes(for: handle)
                } catch {
                    failures.append(WindowReadFailure(processIdentifier: application.processIdentifier, kind: .attributes))
                    skipped.append(WindowSkip(processIdentifier: application.processIdentifier, reason: .readFailure))
                    continue
                }
                recordDiagnostic(
                    "[ScreenSwapCandidate] ordinal=\(candidateOrdinal) role=\(attributes.role) subrole=\(attributes.subrole ?? "none") minimized=\(attributes.isMinimized) movable=\(attributes.positionIsSettable) resizable=\(attributes.sizeIsSettable) full_screen=\(format(attributes.presentationState.isFullScreen)) frame=\(format(CGRect(origin: attributes.position, size: attributes.size)))"
                )

                guard case let .eligible(isResizable) = WindowClassifier.classify(attributes) else {
                    skipped.append(WindowSkip(
                        processIdentifier: application.processIdentifier,
                        reason: WindowClassifier.skipReason(for: attributes) ?? .readFailure
                    ))
                    continue
                }
                let frame = CGRect(origin: attributes.position, size: attributes.size)
                let visibleIndex = VisibleWindowMatcher.matchIndex(
                    processIdentifier: application.processIdentifier,
                    frame: frame,
                    candidates: unmatchedVisibleWindows
                )
                // Native full-screen windows can occupy a dedicated visible
                // Space that Quartz omits from this process's normal
                // on-screen list. Keep the normal Quartz requirement for all
                // other windows (including Stage Manager-hidden ones), but
                // allow an AX-confirmed full-screen window through.
                guard visibleIndex != nil || attributes.presentationState.isFullScreen == true else {
                    skipped.append(WindowSkip(processIdentifier: application.processIdentifier, reason: .notVisible))
                    continue
                }
                let visibleWindow = visibleIndex.map { unmatchedVisibleWindows.remove(at: $0) }
                let id = WindowID(
                    processIdentifier: application.processIdentifier,
                    accessibilityIdentifier: UUID().uuidString
                )
                let sourceDisplayID = mapping.sourceDisplayID(for: frame, displayA: displayA, displayB: displayB)
                let sourceDisplay: DisplaySnapshot?
                switch sourceDisplayID {
                case displayA.id:
                    sourceDisplay = displayA
                case displayB.id:
                    sourceDisplay = displayB
                default:
                    sourceDisplay = nil
                }
                let retainedMaximizedIntent = visibleWindow?.windowNumber.map(maximizedWindowNumbers.contains) == true
                let fillsSourceVisibleFrame = sourceDisplay.map { fillsVisibleFrame(frame, on: $0) } == true
                let isVisuallyMaximized = attributes.presentationState.isFullScreen != true &&
                    (retainedMaximizedIntent || fillsSourceVisibleFrame)
                if attributes.presentationState.isZoomed == true {
                    knownZoomedCount += 1
                } else if attributes.presentationState.isZoomed == nil {
                    unknownZoomStateCount += 1
                }
                if fillsSourceVisibleFrame {
                    geometryMaximizedCount += 1
                }
                if retainedMaximizedIntent {
                    retainedMaximizedCount += 1
                }
                // A window manager may report a maximized decorated window
                // one point beyond a display edge (for example x=1919 for a
                // visible frame beginning at x=1920). Preserve the visible
                // frame intent before the core's strict full-frame spanning
                // check. Ordinary windows retain their exact AX frame, so
                // genuinely spanning windows remain untouched.
                let snapshotFrame: CGRect
                if isVisuallyMaximized {
                    snapshotFrame = sourceDisplay?.visibleFrame ?? frame
                } else if let sourceDisplay,
                          !spansBothDisplays(frame, displayA: displayA, displayB: displayB) {
                    snapshotFrame = canonicalizeVisibleEdges(frame, on: sourceDisplay)
                } else {
                    snapshotFrame = frame
                }
                let snapshot = WindowSnapshot(
                    id: id,
                    sourceDisplayID: sourceDisplayID,
                    frame: snapshotFrame
                )
                captured.append(
                    CapturedWindow(
                        snapshot: snapshot,
                        isResizable: isResizable,
                        presentationState: attributes.presentationState,
                        isVisuallyMaximized: isVisuallyMaximized,
                        runtimeKey: visibleWindow?.windowNumber.map {
                            RuntimeWindowKey(processIdentifier: application.processIdentifier, quartzWindowNumber: $0)
                        }
                    )
                )
                nextLookup[id] = handle
                nextPresentationStates[id] = attributes.presentationState
                // Preserve the actual AX geometry for a later position-only
                // restore. `snapshotFrame` may be canonicalized to express a
                // maximized layout intent and must not replace this value.
                nextSourceFrames[id] = frame
                if isVisuallyMaximized {
                    nextVisuallyMaximizedWindowIDs.insert(id)
                }
                if (isVisuallyMaximized || attributes.presentationState.isZoomed == true),
                   let windowNumber = visibleWindow?.windowNumber {
                    nextMaximizedWindowNumbers.insert(windowNumber)
                }
            }
        }

        lookup = nextLookup
        presentationStates = nextPresentationStates
        visuallyMaximizedWindowIDs = nextVisuallyMaximizedWindowIDs
        maximizedWindowNumbers = nextMaximizedWindowNumbers
        displaysByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        sourceFrames = nextSourceFrames
        sourceDisplayIDs = Dictionary(uniqueKeysWithValues: captured.map { ($0.snapshot.id, $0.snapshot.sourceDisplayID) })
        diagnosticWindowOrdinals = Dictionary(
            uniqueKeysWithValues: captured.enumerated().map { ($0.element.snapshot.id, $0.offset + 1) }
        )
        let skippedSummary = Dictionary(grouping: skipped, by: \.reason)
            .map { "\($0.key.rawValue)=\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        recordDiagnostic(
            "[ScreenSwapCapture] displays=\(displays.map(format).joined(separator: ";")) total=\(totalWindows) eligible=\(captured.count) failures=\(failures.count) skipped=\(skippedSummary.isEmpty ? "none" : skippedSummary) geometry_maximized=\(geometryMaximizedCount) retained_maximized=\(retainedMaximizedCount) known_zoomed=\(knownZoomedCount) unknown_zoom_state=\(unknownZoomStateCount)"
        )
        for (offset, capturedWindow) in captured.enumerated() {
            let sourceDisplay = displays.first { $0.id == capturedWindow.snapshot.sourceDisplayID }
            recordDiagnostic(
                "[ScreenSwapCaptureWindow] ordinal=\(offset + 1) source=\(capturedWindow.snapshot.sourceDisplayID) frame=\(format(capturedWindow.snapshot.frame)) source_visible=\(sourceDisplay.map { format($0.visibleFrame) } ?? "none") visual_maximized=\(capturedWindow.isVisuallyMaximized) zoom=\(format(capturedWindow.presentationState.isZoomed)) zoom_button=\(capturedWindow.presentationState.canToggleZoom)"
            )
        }
        return WindowCaptureBatch(
            windows: captured,
            failures: failures,
            totalWindows: totalWindows,
            skipped: skipped
        )
    }

    private func isAuxiliaryApplication(_ application: AccessibilityApplication) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier else { return false }
        let knownAuxiliaryBundles: Set<String> = [
            "com.apple.notificationcenterui",
            "com.apple.dock",
            "com.apple.controlcenter"
        ]
        return knownAuxiliaryBundles.contains(bundleIdentifier) ||
            bundleIdentifier.hasPrefix("com.apple.widget")
    }

    private func fillsVisibleFrame(_ frame: CGRect, on display: DisplaySnapshot) -> Bool {
        // AX and AppKit can disagree slightly about title bars, shadows, and
        // safe-area edges. Require the window to substantially occupy the
        // source visible frame, rather than requiring pixel-identical bounds.
        let visibleFrame = display.visibleFrame
        let intersection = frame.intersection(visibleFrame)
        guard !intersection.isNull, visibleFrame.width > 0, visibleFrame.height > 0 else {
            return false
        }
        let coverage = (intersection.width * intersection.height) / (visibleFrame.width * visibleFrame.height)
        let edgeTolerance: CGFloat = 24
        let horizontalInset = max(abs(frame.minX - visibleFrame.minX), abs(frame.maxX - visibleFrame.maxX))
        let verticalInset = max(abs(frame.minY - visibleFrame.minY), abs(frame.maxY - visibleFrame.maxY))
        // The relative allowance avoids losing maximized intent when a window
        // crosses displays with different scales, title-bar metrics, or safe
        // areas. It remains much tighter than a merely large normal window.
        let alignsWithVisibleFrame = horizontalInset <= max(edgeTolerance, visibleFrame.width * 0.05) &&
            verticalInset <= max(edgeTolerance, visibleFrame.height * 0.05)
        // Keep the full-display comparison much tighter than the
        // visible-frame comparison. A menu bar or dock can itself be 24
        // points wide, so using `edgeTolerance` here makes a window that
        // exactly fills the visible frame look like it also fills the entire
        // display. That loses windowed-maximized intent on every return to a
        // display with an inset.
        let fullDisplayTolerance: CGFloat = 2
        let fillsFullDisplay = abs(frame.minX - display.frame.minX) <= fullDisplayTolerance &&
            abs(frame.maxX - display.frame.maxX) <= fullDisplayTolerance &&
            abs(frame.minY - display.frame.minY) <= fullDisplayTolerance &&
            abs(frame.maxY - display.frame.maxY) <= fullDisplayTolerance
        return coverage >= 0.92 && alignsWithVisibleFrame &&
            !(display.visibleFrame != display.frame && fillsFullDisplay)
    }

    /// Preserve a window manager's edge-to-edge layout intent when AX reports
    /// a one- or two-point discrepancy at a visible-frame edge. This matters
    /// for tiled halves: without it, a height reported as 967 instead of 968
    /// is proportionally projected as 769 on the other display and drifts on
    /// every later swap. Leave a spanning frame untouched so the core can
    /// continue to exclude it from the move plan.
    private func canonicalizeVisibleEdges(_ frame: CGRect, on display: DisplaySnapshot) -> CGRect {
        let visibleFrame = display.visibleFrame
        let edgeTolerance: CGFloat = 2
        let fillsVisibleHeight = abs(frame.minY - visibleFrame.minY) <= edgeTolerance &&
            abs(frame.maxY - visibleFrame.maxY) <= edgeTolerance
        let fillsVisibleWidth = abs(frame.minX - visibleFrame.minX) <= edgeTolerance &&
            abs(frame.maxX - visibleFrame.maxX) <= edgeTolerance
        return CGRect(
            x: fillsVisibleWidth ? visibleFrame.minX : frame.minX,
            y: fillsVisibleHeight ? visibleFrame.minY : frame.minY,
            width: fillsVisibleWidth ? visibleFrame.width : frame.width,
            height: fillsVisibleHeight ? visibleFrame.height : frame.height
        )
    }

    private func spansBothDisplays(
        _ frame: CGRect,
        displayA: DisplaySnapshot,
        displayB: DisplaySnapshot
    ) -> Bool {
        hasPositiveAreaIntersection(frame, displayA.frame) &&
            hasPositiveAreaIntersection(frame, displayB.frame)
    }

    private func hasPositiveAreaIntersection(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let overlap = lhs.intersection(rhs)
        return !overlap.isNull && overlap.width > 0 && overlap.height > 0
    }

    public func apply(move: WindowMove, isResizable: Bool) -> WindowApplyResult {
        guard let handle = lookup[move.windowID] else {
            return WindowApplyResult(succeeded: false, failure: .staleWindow)
        }

        let presentation = presentationStates[move.windowID] ?? .unknown
        let wasZoomed = presentation.isZoomed == true
        let wasFullScreen = presentation.isFullScreen == true
        let wasVisuallyMaximized = visuallyMaximizedWindowIDs.contains(move.windowID)

        recordDiagnostic(
            "[ScreenSwapApplyStart] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) destination=\(move.destinationDisplayID) resizable=\(isResizable) full_screen=\(wasFullScreen) visual_maximized=\(wasVisuallyMaximized)"
        )

        if wasZoomed && (!isResizable || !presentation.canToggleZoom) {
            return WindowApplyResult(succeeded: false, failure: .zoom)
        }
        if wasFullScreen && !presentation.canToggleFullScreen {
            return WindowApplyResult(succeeded: false, failure: .fullScreen)
        }

        var zoomIsTemporarilyExited = false
        var fullScreenIsTemporarilyExited = false
        func restoreOriginalPresentation() {
            if zoomIsTemporarilyExited {
                _ = transitionZoom(handle, to: true)
                zoomIsTemporarilyExited = false
            }
            if fullScreenIsTemporarilyExited {
                _ = transitionFullScreen(handle, to: true)
                fullScreenIsTemporarilyExited = false
            }
        }

        if wasFullScreen {
            do {
                try client.activateApplication(for: handle)
                recordDiagnostic("[ScreenSwapTransition] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) kind=full_screen phase=application_activated")
            } catch {
                recordDiagnostic("[ScreenSwapTransition] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) kind=full_screen result=activation_failed")
                return WindowApplyResult(succeeded: false, failure: .fullScreen)
            }
            guard transitionFullScreen(handle, to: false) else {
                return WindowApplyResult(succeeded: false, failure: .fullScreen)
            }
            fullScreenIsTemporarilyExited = true
        }

        if wasZoomed {
            guard transitionZoom(handle, to: false) else {
                restoreOriginalPresentation()
                return WindowApplyResult(succeeded: false, failure: .zoom)
            }
            zoomIsTemporarilyExited = true
        }

        let destinationFrame = resolvedDestinationFrame(
            for: move,
            isResizable: isResizable
        )
        recordDiagnostic(
            "[ScreenSwapApply] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) destination=\(move.destinationDisplayID) requested=\(format(destinationFrame)) resizable=\(isResizable) visual_maximized=\(wasVisuallyMaximized) zoom=\(format(presentation.isZoomed))"
        )

        // macOS can clamp a resize to the window's *current* display. This
        // affects ordinary tiled windows as well as visually maximized ones:
        // a half-width window moved from a shorter display to a taller one
        // must cross to the destination before its height can grow. Keep the
        // normal size-first sequence for proportional growth that still fits
        // within the source display.
        let destinationExceedsSourceDisplay = sourceDisplayIDs[move.windowID]
            .flatMap { displaysByID[$0] }
            .map {
                destinationFrame.width > $0.visibleFrame.width + 4 ||
                destinationFrame.height > $0.visibleFrame.height + 4
            } ?? false
        let shouldMoveBeforeGrowing = isResizable && !wasZoomed && !wasFullScreen &&
            destinationExceedsSourceDisplay

        if shouldMoveBeforeGrowing {
            do {
                try client.setPosition(destinationFrame.origin, for: handle)
            } catch {
                recordDiagnostic("[ScreenSwapApplyFailure] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) phase=pre_resize_position")
                restoreOriginalPresentation()
                return WindowApplyResult(succeeded: false, failure: .position)
            }
        }

        // A native full-screen AX window often advertises non-settable size
        // while it owns its dedicated Space. Once exited above, it must be
        // resized to the destination display before native full-screen is
        // restored. Do not change the position-only rule for ordinary
        // non-resizable windows.
        let shouldResize = isResizable || wasFullScreen
        if shouldResize {
            do {
                try client.setSize(destinationFrame.size, for: handle)
            } catch {
                recordDiagnostic("[ScreenSwapApplyFailure] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) phase=size")
                restoreOriginalPresentation()
                return WindowApplyResult(succeeded: false, failure: .size)
            }
        }

        do {
            try client.setPosition(destinationFrame.origin, for: handle)
        } catch {
            recordDiagnostic("[ScreenSwapApplyFailure] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) phase=position")
            restoreOriginalPresentation()
            return WindowApplyResult(succeeded: false, failure: .position)
        }

        // Some macOS window managers acknowledge a size write for a tiled
        // window but defer (or discard) it until the window has crossed to
        // its new display. Re-read after the first final position and, only
        // when the requested size is still materially different, apply the
        // size and final position once more on the destination. The second
        // position write is important: the first write may have been clamped
        // using the old, larger frame.
        var actualFrame = (try? client.attributes(for: handle)).map {
            CGRect(origin: $0.position, size: $0.size)
        }
        if shouldResize,
           let initialFrame = actualFrame,
           !hasExpectedSize(initialFrame.size, expected: destinationFrame.size),
           hasReachedDestination(initialFrame, displayID: move.destinationDisplayID) {
            recordDiagnostic("[ScreenSwapApplyRetry] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) reason=size_not_applied")
            do {
                try client.setSize(destinationFrame.size, for: handle)
            } catch {
                recordDiagnostic("[ScreenSwapApplyFailure] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) phase=retry_size")
                restoreOriginalPresentation()
                return WindowApplyResult(succeeded: false, failure: .size)
            }
            do {
                try client.setPosition(destinationFrame.origin, for: handle)
            } catch {
                recordDiagnostic("[ScreenSwapApplyFailure] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) phase=retry_position")
                restoreOriginalPresentation()
                return WindowApplyResult(succeeded: false, failure: .position)
            }
            actualFrame = (try? client.attributes(for: handle)).map {
                CGRect(origin: $0.position, size: $0.size)
            }
        }
        if let actualFrame,
           let actualAttributes = try? client.attributes(for: handle) {
            recordDiagnostic(
                "[ScreenSwapApplyResult] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) actual=\(format(actualFrame)) zoom=\(format(actualAttributes.presentationState.isZoomed))"
            )
        }

        let fillsDestinationVisibleFrame = actualFrame.map { actualFrame in
            displaysByID[move.destinationDisplayID].map {
                fillsVisibleFrame(actualFrame, on: $0)
            } ?? false
        } ?? false
        if wasVisuallyMaximized,
           shouldResize,
           !fillsDestinationVisibleFrame {
            recordDiagnostic("[ScreenSwapApplyFailure] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) phase=windowed_maximize_readback")
            return WindowApplyResult(succeeded: false, failure: .size)
        }

        if wasZoomed {
            guard transitionZoom(handle, to: true) else {
                restoreOriginalPresentation()
                return WindowApplyResult(succeeded: false, failure: .zoom)
            }
            zoomIsTemporarilyExited = false
        }
        if wasFullScreen {
            guard transitionFullScreen(handle, to: true) else {
                restoreOriginalPresentation()
                return WindowApplyResult(succeeded: false, failure: .fullScreen)
            }
            fullScreenIsTemporarilyExited = false
        }
        return .success
    }

    /// Resolves the actual frame requested from AX. The core planner correctly
    /// uses scaled geometry, while this adapter alone knows whether a window
    /// can resize. Fixed-size windows therefore keep their captured size and
    /// have their planner-selected origin clamped against that real size.
    private func resolvedDestinationFrame(
        for move: WindowMove,
        isResizable: Bool
    ) -> CGRect {
        let presentation = presentationStates[move.windowID] ?? .unknown

        if presentation.isFullScreen == true,
           let destination = displaysByID[move.destinationDisplayID] {
            // Native full-screen does not respect the destination's dock or
            // menu-bar inset. Anchor the temporary window to the complete
            // target display before restoring its native full-screen state.
            return destination.frame
        }

        if presentation.isZoomed == true ||
            visuallyMaximizedWindowIDs.contains(move.windowID),
           let destination = displaysByID[move.destinationDisplayID] {
            return destination.visibleFrame
        }

        guard !isResizable,
              let sourceFrame = sourceFrames[move.windowID],
              let destination = displaysByID[move.destinationDisplayID] else {
            return move.frame
        }

        return clampPositionOnly(
            CGRect(origin: move.frame.origin, size: sourceFrame.size),
            to: destination.visibleFrame
        )
    }

    private func clampPositionOnly(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - frame.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - frame.height)
        return CGRect(
            x: min(max(frame.minX, visibleFrame.minX), maxX),
            y: min(max(frame.minY, visibleFrame.minY), maxY),
            width: frame.width,
            height: frame.height
        )
    }

    public func restore(windowID: WindowID, isResizable: Bool) -> WindowApplyResult {
        func failure(_ kind: WindowApplyFailureKind) -> WindowApplyResult {
            recordDiagnostic(
                "[ScreenSwapRollback] ordinal=\(diagnosticWindowOrdinals[windowID] ?? 0) result=failed phase=\(kind.rawValue)"
            )
            return WindowApplyResult(succeeded: false, failure: kind)
        }
        guard let handle = lookup[windowID],
              let sourceFrame = sourceFrames[windowID] else {
            return failure(.staleWindow)
        }

        let presentation = presentationStates[windowID] ?? .unknown
        let wasZoomed = presentation.isZoomed == true
        guard !wasZoomed || presentation.canToggleZoom else {
            return failure(.zoom)
        }
        if wasZoomed, !transitionZoom(handle, to: false) {
            return failure(.zoom)
        }

        if isResizable {
            // The failed move may have left this window on a smaller display.
            // Cross back first, before asking AX to restore a source size that
            // does not fit there. This mirrors `apply`'s move-before-growing
            // rule and avoids a clamped or discarded rollback resize.
            do {
                try client.setPosition(sourceFrame.origin, for: handle)
            } catch {
                if wasZoomed { _ = transitionZoom(handle, to: true) }
                return failure(.position)
            }
            do {
                try client.setSize(sourceFrame.size, for: handle)
            } catch {
                if wasZoomed { _ = transitionZoom(handle, to: true) }
                return failure(.size)
            }
        }
        do {
            // Resizing can change the allowed origin, so always finish with a
            // final source position after the size request.
            try client.setPosition(sourceFrame.origin, for: handle)
        } catch {
            if wasZoomed { _ = transitionZoom(handle, to: true) }
            return failure(.position)
        }
        if wasZoomed, !transitionZoom(handle, to: true) {
            return failure(.zoom)
        }
        recordDiagnostic(
            "[ScreenSwapRollback] ordinal=\(diagnosticWindowOrdinals[windowID] ?? 0) result=restored"
        )
        return .success
    }

    private func transitionZoom(_ handle: AccessibilityWindowHandle, to expected: Bool) -> Bool {
        let ordinal = diagnosticOrdinal(for: handle)
        recordDiagnostic("[ScreenSwapTransition] ordinal=\(ordinal) kind=zoom expected=\(expected) phase=action")
        do {
            try client.pressZoom(for: handle)
        } catch {
            recordDiagnostic("[ScreenSwapTransition] ordinal=\(ordinal) kind=zoom expected=\(expected) result=action_failed")
            return false
        }
        let transitioned = waitForAttributes(handle) { $0.presentationState.isZoomed == expected }
        recordDiagnostic("[ScreenSwapTransition] ordinal=\(ordinal) kind=zoom expected=\(expected) result=\(transitioned ? "confirmed" : "timed_out")")
        return transitioned
    }

    private func transitionFullScreen(_ handle: AccessibilityWindowHandle, to expected: Bool) -> Bool {
        let ordinal = diagnosticOrdinal(for: handle)
        let action: String
        do {
            try client.setFullScreen(expected, for: handle)
            action = "attribute"
        } catch {
            do {
                try client.pressFullScreen(for: handle)
                action = "button"
            } catch {
                recordDiagnostic("[ScreenSwapTransition] ordinal=\(ordinal) kind=full_screen expected=\(expected) result=action_failed")
                return false
            }
        }
        recordDiagnostic("[ScreenSwapTransition] ordinal=\(ordinal) kind=full_screen expected=\(expected) phase=action method=\(action)")
        let transitioned = waitForAttributes(handle) { $0.presentationState.isFullScreen == expected }
        recordDiagnostic("[ScreenSwapTransition] ordinal=\(ordinal) kind=full_screen expected=\(expected) result=\(transitioned ? "confirmed" : "timed_out")")
        return transitioned
    }

    private func waitForAttributes(
        _ handle: AccessibilityWindowHandle,
        matching predicate: (AccessibilityWindowAttributes) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, transitionPolicy.timeout))
        while true {
            guard let attributes = try? client.attributes(for: handle) else { return false }
            if predicate(attributes) { return true }
            guard Date() < deadline else { return false }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            transitionWaiter.wait(for: min(max(0.001, transitionPolicy.pollInterval), remaining))
        }
    }

    public func verificationStatus(
        for move: WindowMove,
        isResizable: Bool,
        tolerance: CGFloat
    ) -> WindowVerificationStatus {
        guard let handle = lookup[move.windowID],
              let attributes = try? client.attributes(for: handle) else {
            return .unavailable
        }
        let actual = CGRect(origin: attributes.position, size: attributes.size)
        if presentationStates[move.windowID]?.isFullScreen == true,
           let destination = displaysByID[move.destinationDisplayID] {
            let stateMatches = attributes.presentationState.isFullScreen == true
            let destinationMatches = destination.frame.contains(
                CGPoint(x: actual.midX, y: actual.midY)
            )
            return stateMatches && destinationMatches ? .verified : .pending
        }
        let expected = resolvedDestinationFrame(for: move, isResizable: isResizable)
        let positionMatches = abs(actual.origin.x - expected.origin.x) <= tolerance &&
            abs(actual.origin.y - expected.origin.y) <= tolerance
        let sizeMatches = !isResizable || (
            abs(actual.width - expected.width) <= tolerance &&
            abs(actual.height - expected.height) <= tolerance
        )
        guard positionMatches && sizeMatches else { return .pending }

        // AX can retain a correct global frame for a window that macOS has
        // left in an inactive Space. An ordinary window is only a successful
        // swap when Quartz reports it on screen after all presentation
        // transitions have completed. Native full-screen windows are exempt:
        // Quartz may omit their dedicated Space even while AX confirms their
        // full-screen state and destination frame above.
        guard let visibleWindows = try? client.visibleWindows() else {
            return .unavailable
        }
        let isVisible = VisibleWindowMatcher.matchIndex(
            processIdentifier: move.windowID.processIdentifier,
            frame: actual,
            candidates: visibleWindows
        ) != nil
        if !isVisible {
            recordDiagnostic(
                "[ScreenSwapVerification] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) result=not_visible"
            )
        }
        return isVisible ? .verified : .notVisible
    }

    private func recordDiagnostic(_ message: @autoclosure () -> String) {
        guard DiagnosticsConfiguration.isEnabled(
            environment: ProcessInfo.processInfo.environment,
            localOverride: localDiagnosticsEnabled
        ) else { return }
        let resolvedMessage = message()
        Self.diagnosticLogger.notice("\(resolvedMessage, privacy: .public)")
        DiagnosticsConfiguration.append(resolvedMessage, environment: ProcessInfo.processInfo.environment)
    }

    private func hasExpectedSize(_ actual: CGSize, expected: CGSize) -> Bool {
        let tolerance: CGFloat = 2
        return abs(actual.width - expected.width) <= tolerance &&
            abs(actual.height - expected.height) <= tolerance
    }

    private func hasReachedDestination(_ frame: CGRect, displayID: UInt32) -> Bool {
        guard let destination = displaysByID[displayID] else { return false }
        return destination.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func diagnosticOrdinal(for handle: AccessibilityWindowHandle) -> Int {
        guard let windowID = lookup.first(where: { $0.value == handle })?.key else { return 0 }
        return diagnosticWindowOrdinals[windowID] ?? 0
    }

    private func format(_ display: DisplaySnapshot) -> String {
        "id=\(display.id),frame=\(format(display.frame)),visible=\(format(display.visibleFrame))"
    }

    private func format(_ frame: CGRect) -> String {
        "x=\(Int(frame.origin.x.rounded())),y=\(Int(frame.origin.y.rounded())),w=\(Int(frame.width.rounded())),h=\(Int(frame.height.rounded()))"
    }

    private func format(_ value: Bool?) -> String {
        value.map(String.init) ?? "unknown"
    }

}
