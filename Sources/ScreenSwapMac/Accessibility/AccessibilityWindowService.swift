import CoreGraphics
import Foundation
import os
import ScreenSwapCore

private struct AccessibilityWindowCandidate {
    let handle: AccessibilityWindowHandle
    let attributes: AccessibilityWindowAttributes
    let frame: CGRect
}

@MainActor
public final class AccessibilityWindowService: DisplayPairWindowProviding, WindowApplying, WindowRestoring, WindowVerifying, WindowVisibilityRecovering, WindowInventoryProviding, DisplayCandidateCounting {
    private static let diagnosticLogger = Logger(subsystem: "com.screenswap.app", category: "diagnostics")
    private let client: any AccessibilityClient
    /// Inventory discovery owns a separate client cache so opening the menu
    /// cannot invalidate AX handles retained by an in-flight swap transaction.
    private let inventoryClient: (any AccessibilityClient)?
    private let processIdentifier: Int32
    private var lookup: [WindowID: AccessibilityWindowHandle] = [:]
    private var presentationStates: [WindowID: WindowPresentationState] = [:]
    private var presentationModes: [WindowID: CapturedPresentationMode] = [:]
    private var runtimeKeysByWindowID: [WindowID: RuntimeWindowKey] = [:]
    private var visibilityRecoveryIDs: Set<WindowID> = []
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
            let candidates = handles.compactMap { handle -> AccessibilityWindowCandidate? in
                guard let attributes = try? reader.attributes(for: handle),
                      attributes.role == "AXWindow",
                      !isTransient(attributes) else { return nil }
                let frame = CGRect(origin: attributes.position, size: attributes.size)
                guard !frame.isEmpty else { return nil }
                return AccessibilityWindowCandidate(handle: handle, attributes: attributes, frame: frame)
            }

            // Reserve every native full-screen Quartz observation before
            // ordinary windows match. AX enumeration order is not a window
            // identity guarantee, so a hidden same-process window cannot
            // inherit a native full-screen surface's visibility record.
            for candidate in candidates where candidate.attributes.presentationState.isFullScreen == true {
                if let visibleIndex = VisibleWindowMatcher.matchIndex(
                    processIdentifier: application.processIdentifier,
                    frame: candidate.frame,
                    candidates: unmatchedVisibleWindows
                ) {
                    unmatchedVisibleWindows.remove(at: visibleIndex)
                }
            }

            for candidate in candidates {
                let attributes = candidate.attributes
                let frame = candidate.frame
                let isNativeFullScreenUnsupported = attributes.presentationState.isFullScreen == true
                // A native full-screen Space can report geometry crossing a
                // display boundary. Keep it visible as an unsupported window
                // instead of presenting the unrelated spanning-window state.
                let isSpanning = !isNativeFullScreenUnsupported && WindowInventoryClassifier.spans(frame, displays: snapshots)
                let displayID = WindowInventoryClassifier.owner(of: frame, displays: snapshots)
                guard isSpanning || displayID != nil else { continue }
                ordinal += 1
                let visible: VisibleWindowSnapshot?
                if isNativeFullScreenUnsupported {
                    visible = nil
                } else {
                    let visibleIndex = VisibleWindowMatcher.matchIndex(
                        processIdentifier: application.processIdentifier,
                        frame: frame,
                        candidates: unmatchedVisibleWindows
                    )
                    visible = visibleIndex.map { unmatchedVisibleWindows.remove(at: $0) }
                }
                let key = visible.flatMap { visibleWindow in
                    visibleWindow.windowNumber.map {
                        RuntimeWindowKey(processIdentifier: application.processIdentifier, quartzWindowNumber: $0)
                    }
                }
                let isEligible = {
                    if case .eligible = WindowClassifier.classify(attributes) { return true }
                    return false
                }()
                windows.append(InventoryWindow(
                    key: key,
                    displayID: displayID,
                    label: WindowInventoryClassifier.label(
                        applicationName: application.localizedName,
                        title: try? reader.title(for: candidate.handle),
                        ordinal: ordinal
                    ),
                    isSelectable: !isSpanning && isEligible && key != nil,
                    isNativeFullScreenUnsupported: isNativeFullScreenUnsupported,
                    isSpanning: isSpanning
                ))
            }
        }
        return WindowInventory(displays: displays, windows: windows)
    }

    public func candidateCounts(activeDisplays: [DisplaySnapshot]) -> [UInt32: Int] {
        let inventoryDisplays = activeDisplays.sorted { $0.id < $1.id }.enumerated().map {
            InventoryDisplay(snapshot: $0.element, ordinal: $0.offset + 1, name: nil)
        }
        let inventory = inventory(displays: inventoryDisplays)
        return inventory.windows.reduce(into: [UInt32: Int]()) { counts, window in
            guard let displayID = window.displayID,
                  !window.isSpanning,
                  window.isSelectable || window.isAutomaticallyIncluded else { return }
            counts[displayID, default: 0] += 1
        }
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
        captureWindows(activeDisplays: displays, selectedDisplays: displays)
    }

    public func captureWindows(
        activeDisplays: [DisplaySnapshot],
        selectedDisplays: [DisplaySnapshot]
    ) -> WindowCaptureBatch {
        guard selectedDisplays.count == 2,
              Set(selectedDisplays.map(\.id)).isSubset(of: Set(activeDisplays.map(\.id))) else {
            lookup = [:]
            presentationStates = [:]
            presentationModes = [:]
            runtimeKeysByWindowID = [:]
            visibilityRecoveryIDs = []
            visuallyMaximizedWindowIDs = []
            maximizedWindowNumbers = []
            displaysByID = [:]
            sourceFrames = [:]
            sourceDisplayIDs = [:]
            return WindowCaptureBatch(windows: [])
        }
        let selectedDisplayIDs = Set(selectedDisplays.map(\.id))
        var captured: [CapturedWindow] = []
        var failures: [WindowReadFailure] = []
        var skipped: [WindowSkip] = []
        var totalWindows = 0
        var nextLookup: [WindowID: AccessibilityWindowHandle] = [:]
        var nextPresentationStates: [WindowID: WindowPresentationState] = [:]
        var nextPresentationModes: [WindowID: CapturedPresentationMode] = [:]
        var nextRuntimeKeys: [WindowID: RuntimeWindowKey] = [:]
        var nextSourceFrames: [WindowID: CGRect] = [:]
        var nextVisuallyMaximizedWindowIDs: Set<WindowID> = []
        var nextMaximizedWindowNumbers: Set<UInt32> = []
        var nextKnownRuntimeKeys: Set<RuntimeWindowKey> = []
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
            presentationModes = [:]
            runtimeKeysByWindowID = [:]
            visibilityRecoveryIDs = []
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
            presentationModes = [:]
            runtimeKeysByWindowID = [:]
            visibilityRecoveryIDs = []
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

            var candidates: [AccessibilityWindowCandidate] = []
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
                candidates.append(AccessibilityWindowCandidate(
                    handle: handle,
                    attributes: attributes,
                    frame: CGRect(origin: attributes.position, size: attributes.size)
                ))
            }

            // Reserve all native full-screen surfaces before processing an
            // ordinary candidate. AX order is not an identity guarantee.
            for candidate in candidates where candidate.attributes.presentationState.isFullScreen == true {
                if let visibleIndex = VisibleWindowMatcher.matchIndex(
                    processIdentifier: application.processIdentifier,
                    frame: candidate.frame,
                    candidates: unmatchedVisibleWindows
                ) {
                    unmatchedVisibleWindows.remove(at: visibleIndex)
                }
                skipped.append(WindowSkip(
                    processIdentifier: application.processIdentifier,
                    reason: .nativeFullScreenSpace
                ))
            }

            for candidate in candidates where candidate.attributes.presentationState.isFullScreen != true {
                let handle = candidate.handle
                let attributes = candidate.attributes
                let frame = candidate.frame
                guard case let .eligible(isResizable) = WindowClassifier.classify(attributes) else {
                    skipped.append(WindowSkip(
                        processIdentifier: application.processIdentifier,
                        reason: WindowClassifier.skipReason(for: attributes) ?? .readFailure
                    ))
                    continue
                }
                let visibleIndex = VisibleWindowMatcher.matchIndex(
                    processIdentifier: application.processIdentifier,
                    frame: frame,
                    candidates: unmatchedVisibleWindows
                )
                // Keep the Quartz visibility requirement for ordinary windows,
                // including Stage Manager-hidden surfaces. Native full-screen
                // candidates were already reserved and excluded above.
                guard visibleIndex != nil else {
                    skipped.append(WindowSkip(processIdentifier: application.processIdentifier, reason: .notVisible))
                    continue
                }
                let visibleWindow = visibleIndex.map { unmatchedVisibleWindows.remove(at: $0) }
                let runtimeKey = visibleWindow?.windowNumber.map {
                    RuntimeWindowKey(processIdentifier: application.processIdentifier, quartzWindowNumber: $0)
                }
                // Resolve both ownership and spanning using the whole active
                // topology before checking whether this window belongs to the
                // selected pair. This prevents a third-display window from
                // being assigned to a selected display by two-display logic.
                let rawIsSpanning = WindowInventoryClassifier.spans(frame, displays: activeDisplays)
                guard let sourceDisplayID = WindowInventoryClassifier.owner(of: frame, displays: activeDisplays),
                      let sourceDisplay = activeDisplays.first(where: { $0.id == sourceDisplayID }) else {
                    skipped.append(WindowSkip(
                        processIdentifier: application.processIdentifier,
                        reason: rawIsSpanning ? .spanningDisplays : .unknownSourceDisplay
                    ))
                    continue
                }
                let tileFrame = isResizable ? canonicalizeTileEdges(frame, on: sourceDisplay) : frame
                let isSpanning = WindowInventoryClassifier.spans(tileFrame, displays: activeDisplays)
                let stillApproximatelyMaximized = frame.width >= sourceDisplay.visibleFrame.width * 0.8 &&
                    frame.height >= sourceDisplay.visibleFrame.height * 0.8
                let retainedMaximizedIntent = stillApproximatelyMaximized &&
                    visibleWindow?.windowNumber.map(maximizedWindowNumbers.contains) == true
                let fillsSourceVisibleFrame = fillsVisibleFrame(frame, on: sourceDisplay)
                let isVisuallyMaximized = attributes.presentationState.isFullScreen != true &&
                    (retainedMaximizedIntent || fillsSourceVisibleFrame)
                // Preserve the established one-point maximized-frame tolerance
                // before applying full-topology spanning classification.
                if isSpanning, !isVisuallyMaximized {
                    skipped.append(WindowSkip(processIdentifier: application.processIdentifier, reason: .spanningDisplays))
                    continue
                }
                if let runtimeKey { nextKnownRuntimeKeys.insert(runtimeKey) }
                guard selectedDisplayIDs.contains(sourceDisplayID) else {
                    skipped.append(WindowSkip(processIdentifier: application.processIdentifier, reason: .unselectedDisplay))
                    continue
                }
                let id = WindowID(
                    processIdentifier: application.processIdentifier,
                    accessibilityIdentifier: UUID().uuidString
                )
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
                    snapshotFrame = sourceDisplay.visibleFrame
                } else {
                    snapshotFrame = canonicalizeVisibleEdges(tileFrame, on: sourceDisplay)
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
                        runtimeKey: runtimeKey
                    )
                )
                nextLookup[id] = handle
                nextPresentationStates[id] = attributes.presentationState
                nextPresentationModes[id] = CapturedPresentationMode.classify(
                    attributes.presentationState,
                    fillsSourceVisibleFrame: fillsSourceVisibleFrame,
                    retainedMaximizedIntent: retainedMaximizedIntent
                )
                if let runtimeKey { nextRuntimeKeys[id] = runtimeKey }
                // Preserve the actual AX geometry for a later position-only
                // restore. `snapshotFrame` may be canonicalized to express a
                // maximized layout intent and must not replace this value.
                nextSourceFrames[id] = frame
                if isVisuallyMaximized {
                    nextVisuallyMaximizedWindowIDs.insert(id)
                }
                if isVisuallyMaximized,
                   let windowNumber = visibleWindow?.windowNumber {
                    nextMaximizedWindowNumbers.insert(windowNumber)
                }
            }
        }

        lookup = nextLookup
        presentationStates = nextPresentationStates
        presentationModes = nextPresentationModes
        runtimeKeysByWindowID = nextRuntimeKeys
        visibilityRecoveryIDs = []
        visuallyMaximizedWindowIDs = nextVisuallyMaximizedWindowIDs
        maximizedWindowNumbers = nextMaximizedWindowNumbers
        displaysByID = Dictionary(uniqueKeysWithValues: activeDisplays.map { ($0.id, $0) })
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
            "[ScreenSwapCapture] active_displays=\(activeDisplays.map(format).joined(separator: ";")) selected_displays=\(selectedDisplays.map(format).joined(separator: ";")) total=\(totalWindows) eligible=\(captured.count) failures=\(failures.count) skipped=\(skippedSummary.isEmpty ? "none" : skippedSummary) geometry_maximized=\(geometryMaximizedCount) retained_maximized=\(retainedMaximizedCount) known_zoomed=\(knownZoomedCount) unknown_zoom_state=\(unknownZoomStateCount)"
        )
        for (offset, capturedWindow) in captured.enumerated() {
            let sourceDisplay = activeDisplays.first { $0.id == capturedWindow.snapshot.sourceDisplayID }
            recordDiagnostic(
                "[ScreenSwapCaptureWindow] ordinal=\(offset + 1) pid=\(capturedWindow.snapshot.id.processIdentifier) runtime_key=\(runtimeKeysByWindowID[capturedWindow.snapshot.id] != nil) mode=\(presentationModes[capturedWindow.snapshot.id]?.rawValue ?? "ordinary") source=\(capturedWindow.snapshot.sourceDisplayID) frame=\(format(capturedWindow.snapshot.frame)) source_visible=\(sourceDisplay.map { format($0.visibleFrame) } ?? "none") visual_maximized=\(capturedWindow.isVisuallyMaximized) zoom=\(format(capturedWindow.presentationState.isZoomed)) zoom_button=\(capturedWindow.presentationState.canToggleZoom)"
            )
        }
        return WindowCaptureBatch(
            windows: captured,
            failures: failures,
            totalWindows: totalWindows,
            skipped: skipped,
            knownRuntimeKeys: nextKnownRuntimeKeys
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

    /// Native tiling decoration may extend one or two points beyond a shared
    /// display edge. Snap only complete half/quarter cells; arbitrary spans
    /// retain their full-topology classification.
    private func canonicalizeTileEdges(_ frame: CGRect, on display: DisplaySnapshot) -> CGRect {
        let visible = display.visibleFrame
        let tolerance: CGFloat = 2
        func snap(_ value: CGFloat, edges: [CGFloat]) -> CGFloat? {
            edges.first { abs(value - $0) <= tolerance }
        }
        guard let minX = snap(frame.minX, edges: [visible.minX, visible.midX, visible.maxX]),
              let maxX = snap(frame.maxX, edges: [visible.minX, visible.midX, visible.maxX]),
              let minY = snap(frame.minY, edges: [visible.minY, visible.midY, visible.maxY]),
              let maxY = snap(frame.maxY, edges: [visible.minY, visible.midY, visible.maxY]),
              maxX > minX, maxY > minY else { return frame }
        let halfWidth = abs((maxX - minX) - visible.width / 2) <= tolerance
        let halfHeight = abs((maxY - minY) - visible.height / 2) <= tolerance
        guard halfWidth || halfHeight else { return frame }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public func apply(move: WindowMove, isResizable: Bool) -> WindowApplyResult {
        guard let handle = lookup[move.windowID] else {
            return WindowApplyResult(succeeded: false, failure: .staleWindow)
        }
        if presentationModes[move.windowID] == .ordinary || presentationModes[move.windowID] == .windowedMaximized {
            return client.withGeometryUpdates(for: handle) {
                applyCaptured(move: move, isResizable: isResizable, handle: handle)
            }
        }
        return applyCaptured(move: move, isResizable: isResizable, handle: handle)
    }

    private func applyCaptured(move: WindowMove, isResizable: Bool, handle: AccessibilityWindowHandle) -> WindowApplyResult {
        let presentation = presentationStates[move.windowID] ?? .unknown
        let wasZoomed = presentationModes[move.windowID] == .nativeZoomed
        let wasFullScreen = presentationModes[move.windowID] == .nativeFullScreen
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
            restoreOriginalPresentation()
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
        if presentationModes[move.windowID] == .nativeFullScreen,
           let destination = displaysByID[move.destinationDisplayID] {
            // Native full-screen does not respect the destination's dock or
            // menu-bar inset. Anchor the temporary window to the complete
            // target display before restoring its native full-screen state.
            return destination.frame
        }

        if presentationModes[move.windowID] == .nativeZoomed ||
            presentationModes[move.windowID] == .windowedMaximized,
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
        guard let handle = lookup[windowID] else {
            return WindowApplyResult(succeeded: false, failure: .staleWindow)
        }
        if presentationModes[windowID] == .ordinary || presentationModes[windowID] == .windowedMaximized {
            return client.withGeometryUpdates(for: handle) {
                restoreCaptured(windowID: windowID, isResizable: isResizable, handle: handle)
            }
        }
        return restoreCaptured(windowID: windowID, isResizable: isResizable, handle: handle)
    }

    private func restoreCaptured(
        windowID: WindowID,
        isResizable: Bool,
        handle: AccessibilityWindowHandle
    ) -> WindowApplyResult {
        func failure(_ kind: WindowApplyFailureKind) -> WindowApplyResult {
            recordDiagnostic(
                "[ScreenSwapRollback] ordinal=\(diagnosticWindowOrdinals[windowID] ?? 0) result=failed phase=\(kind.rawValue)"
            )
            return WindowApplyResult(succeeded: false, failure: kind)
        }
        guard let sourceFrame = sourceFrames[windowID] else {
            return failure(.staleWindow)
        }

        let presentation = presentationStates[windowID] ?? .unknown
        let wasZoomed = presentationModes[windowID] == .nativeZoomed
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

    public func recoverVisibility(for move: WindowMove, isResizable: Bool) -> WindowApplyResult {
        guard let handle = lookup[move.windowID],
              presentationModes[move.windowID] == .ordinary || presentationModes[move.windowID] == .windowedMaximized,
              runtimeKeysByWindowID[move.windowID] != nil,
              !visibilityRecoveryIDs.contains(move.windowID),
              verificationStatus(for: move, isResizable: isResizable, tolerance: 2) == .notVisible else {
            return WindowApplyResult(succeeded: false, failure: .visibility)
        }
        visibilityRecoveryIDs.insert(move.windowID)
        recordDiagnostic("[ScreenSwapVisibilityRecovery] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) phase=raise")
        do {
            try client.raise(handle)
        } catch {
            return WindowApplyResult(succeeded: false, failure: .visibility)
        }
        if verificationStatus(for: move, isResizable: isResizable, tolerance: 2) == .pending {
            return apply(move: move, isResizable: isResizable)
        }
        return .success
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
        if presentationModes[move.windowID] == .nativeFullScreen,
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
        guard let visibleWindows = try? client.visibleWindows() else {
            return .unavailable
        }
        let visibleWindow: VisibleWindowSnapshot?
        if let key = runtimeKeysByWindowID[move.windowID] {
            visibleWindow = visibleWindows.first {
                $0.processIdentifier == key.processIdentifier && $0.windowNumber == key.quartzWindowNumber
            }
        } else {
            visibleWindow = VisibleWindowMatcher.matchIndex(
                processIdentifier: move.windowID.processIdentifier,
                frame: actual,
                candidates: visibleWindows
            ).map { visibleWindows[$0] }
        }
        let identityMatches = visibleWindow != nil
        let isVisible = visibleWindow.map {
            abs($0.frame.minX - actual.minX) <= 24 && abs($0.frame.minY - actual.minY) <= 24 &&
            abs($0.frame.width - actual.width) <= 48 && abs($0.frame.height - actual.height) <= 48
        } ?? false
        let geometryMatches = positionMatches && sizeMatches
        let result: WindowVerificationStatus = !geometryMatches ? .pending : (isVisible ? .verified : .notVisible)
        recordDiagnostic(
            "[ScreenSwapVerification] ordinal=\(diagnosticWindowOrdinals[move.windowID] ?? 0) identity_match=\(identityMatches) geometry_match=\(geometryMatches) visible=\(isVisible) result=\(result) actual=\(format(actual)) expected=\(format(expected)) quartz_frame=\(visibleWindow.map { format($0.frame) } ?? "none")"
        )
        return result
    }

    private func recordDiagnostic(_ message: @autoclosure () -> String) {
        guard DiagnosticsConfiguration.isEnabled(
            environment: ProcessInfo.processInfo.environment,
            localOverride: localDiagnosticsEnabled
        ) else { return }
        let resolvedMessage = message()
        Self.diagnosticLogger.notice("\(resolvedMessage, privacy: .public)")
        DiagnosticsConfiguration.append(resolvedMessage, environment: ProcessInfo.processInfo.environment, localOverride: localDiagnosticsEnabled)
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
