import ScreenSwapCore
import Foundation

@MainActor
public final class SwapCoordinator {
    private let authorization: any AccessibilityAuthorizing
    private let displays: any DisplayProviding
    private let windowProvider: any WindowProviding
    private let windowApplying: any WindowApplying
    private let windowRestorer: (any WindowRestoring)?
    private let windowVerifier: (any WindowVerifying)?
    private let windowVisibilityRecoverer: (any WindowVisibilityRecovering)?
    private let planner: any SwapPlanning
    private let clock: any MonotonicTimeSource
    private let performanceRecorder: (any SwapPerformanceRecording)?
    private let selection: (any SwapSelectionProviding)?
    private let displaySelection: DisplayPairSelectionStore
    private var isRunning = false
    private struct CalledWindow {
        let key: RuntimeWindowKey
        let sourceDisplayID: UInt32
        let primaryDisplayID: UInt32
        let originalFrame: CGRect
        var verified: Bool
    }
    private var calledWindow: CalledWindow?
    public var hasPendingReturn: Bool { calledWindow != nil }
    public var calledWindowIsVerified: Bool { calledWindow?.verified == true }

    /// Forget recovery intent without mutating any window.
    public func cancelCallReturn() {
        guard !isRunning else { return }
        calledWindow = nil
    }
    public private(set) var lastDiagnostics = SwapDiagnostics.empty
    /// Transaction-local AX handles are deliberately not retained. This is the
    /// latest immutable pre-swap geometry snapshot for a future undo action.
    public private(set) var latestPreSwapSnapshots: [WindowSnapshot] = []
    /// Exact runtime identities that completed the latest transaction. This
    /// lets the status menu patch its cached grouping without AX rediscovery.
    public private(set) var latestSuccessfulWindowMoves: [SuccessfulWindowMove] = []
    /// Frozen geometry for presentation of a verified focused-window move.
    /// No Accessibility handles or private window metadata are retained.
    public private(set) var latestFocusedMoveRoute: (source: DisplaySnapshot, destination: DisplaySnapshot)?

    public init(
        authorization: any AccessibilityAuthorizing,
        displays: any DisplayProviding,
        windowProvider: any WindowProviding,
        windowApplying: any WindowApplying,
        windowRestorer: (any WindowRestoring)? = nil,
        planner: any SwapPlanning = WindowMappingEngine(),
        windowVerifier: (any WindowVerifying)? = nil,
        windowVisibilityRecoverer: (any WindowVisibilityRecovering)? = nil,
        selection: (any SwapSelectionProviding)? = nil,
        displaySelection: DisplayPairSelectionStore = DisplayPairSelectionStore(),
        clock: any MonotonicTimeSource = MachContinuousTimeSource(),
        performanceRecorder: (any SwapPerformanceRecording)? = nil
    ) {
        self.authorization = authorization
        self.displays = displays
        self.windowProvider = windowProvider
        self.windowApplying = windowApplying
        self.windowRestorer = windowRestorer
        self.planner = planner
        self.windowVerifier = windowVerifier
        self.windowVisibilityRecoverer = windowVisibilityRecoverer
        self.clock = clock
        self.performanceRecorder = performanceRecorder
        self.selection = selection
        self.displaySelection = displaySelection
    }

    public func swap() -> SwapOutcome {
        guard !hasPendingReturn else { lastDiagnostics = .empty; return .noMoves }
        guard !isRunning else {
            lastDiagnostics = .empty
            return .alreadyRunning
        }
        isRunning = true
        defer { isRunning = false }
        latestSuccessfulWindowMoves = []
        latestFocusedMoveRoute = nil

        guard authorization.isTrusted else {
            lastDiagnostics = .empty
            return .noPermission
        }

        let currentDisplays: [DisplaySnapshot]
        do {
            currentDisplays = try displays.currentDisplays()
        } catch {
            lastDiagnostics = .empty
            return .unsupportedDisplayCount(0)
        }
        guard currentDisplays.count >= 2 else {
            lastDiagnostics = .empty
            return .unsupportedDisplayCount(currentDisplays.count)
        }

        guard let (displayA, displayB) = frozenPair(from: currentDisplays) else {
            lastDiagnostics = .empty
            return .unsupportedDisplayCount(currentDisplays.count)
        }
        let batch = capture(activeDisplays: currentDisplays, selectedDisplays: [displayA, displayB])
        latestPreSwapSnapshots = batch.windows.map(\.snapshot)
        guard topologyMatches(currentDisplays) else {
            lastDiagnostics = topologyChangedDiagnostics(batch: batch, displayA: displayA, displayB: displayB)
            return .displayTopologyChanged
        }
        selection?.reconcile(batch.knownRuntimeKeys)
        let selectedKeys = selection?.frozenSelectedKeys()
        let selectedWindows = batch.windows.filter { window in
            guard window.presentationState.isFullScreen != true else { return false }
            guard let selectedKeys else { return true }
            return window.runtimeKey.map { selectedKeys.contains($0) } ?? true
        }
        if selectedKeys != nil && selectedWindows.isEmpty && batch.windows.contains(where: { $0.presentationState.isFullScreen != true }) {
            lastDiagnostics = makeDiagnostics(
                batch: batch,
                selectedWindows: [],
                moves: [],
                displayA: displayA,
                displayB: displayB,
                attempted: 0,
                succeeded: 0,
                failed: 0
            )
            return .noSelection
        }
        let snapshots = selectedWindows.map(\.snapshot)
        let selectedIDs = Set(snapshots.map(\.id))
        let moves = planner.makeSwapMoves(
            windows: snapshots,
            displayA: displayA,
            displayB: displayB
        ).filter { selectedIDs.contains($0.windowID) }
        let orderedMoves = moves
        let capabilities = Dictionary(uniqueKeysWithValues: batch.windows.map { ($0.snapshot.id, $0.isResizable) })

        // A display may disconnect or change scale/arrangement while planning.
        // Recheck immediately before the first AX write rather than applying
        // stale destination geometry to a changed topology.
        guard topologyMatches(currentDisplays) else {
            lastDiagnostics = makeDiagnostics(
                batch: batch,
                selectedWindows: selectedWindows,
                moves: moves,
                displayA: displayA,
                displayB: displayB,
                attempted: 0,
                succeeded: 0,
                failed: 0
            )
            return .displayTopologyChanged
        }

        var attempted = 0
        var succeeded = 0
        var failedIDs = Set<WindowID>()
        for move in orderedMoves {
            attempted += 1
            guard let isResizable = capabilities[move.windowID] else {
                failedIDs.insert(move.windowID)
                continue
            }
            if windowApplying.apply(move: move, isResizable: isResizable).succeeded {
                succeeded += 1
            } else {
                failedIDs.insert(move.windowID)
            }
        }

        latestSuccessfulWindowMoves = successfulWindowMoves(
            batch: batch,
            moves: moves,
            failedIDs: failedIDs
        )

        let failed = attempted - succeeded
        lastDiagnostics = makeDiagnostics(
            batch: batch,
            selectedWindows: selectedWindows,
            moves: moves,
            displayA: displayA,
            displayB: displayB,
            attempted: attempted,
            succeeded: succeeded,
            failed: failed
        )
        if moves.isEmpty {
            return .noMoves
        }
        if failed == 0 {
            return .success(attempted: attempted, succeeded: succeeded)
        }
        return .partialFailure(attempted: attempted, succeeded: succeeded, failed: failed)
    }

    /// Capture T0 at the synchronous command entry point before scheduling any
    /// asynchronous verification work.
    public func commandReceivedNanoseconds() -> UInt64 {
        clock.nowNanoseconds()
    }

    /// Performs a complete measured operation. T0 must be captured at the
    /// command entry point and passed in by UI/benchmark callers. AX writes are
    /// all issued before verification starts; verification polls at most every
    /// five milliseconds and never adds a presentation delay.
    public func swapMeasured(commandReceivedNanoseconds: UInt64? = nil) async -> MeasuredSwapResult {
        await performMeasured(commandReceivedNanoseconds: commandReceivedNanoseconds, focusedWindowKey: nil)
    }

    /// Move only the focused runtime window across the selected display pair.
    /// The full eligible batch is still captured before planning and writing.
    public func moveFocusedWindowMeasured(
        _ key: RuntimeWindowKey,
        commandReceivedNanoseconds: UInt64? = nil
    ) async -> MeasuredSwapResult {
        await performMeasured(commandReceivedNanoseconds: commandReceivedNanoseconds, focusedWindowKey: key)
    }

    public func callReturnMeasured(commandReceivedNanoseconds: UInt64? = nil) async -> MeasuredSwapResult {
        await performMeasured(commandReceivedNanoseconds: commandReceivedNanoseconds, focusedWindowKey: nil, callReturn: true)
    }

    private func performMeasured(
        commandReceivedNanoseconds: UInt64?,
        focusedWindowKey: RuntimeWindowKey?,
        callReturn: Bool = false
    ) async -> MeasuredSwapResult {
        let t0 = commandReceivedNanoseconds ?? clock.nowNanoseconds()
        guard !isRunning else {
            lastDiagnostics = .empty
            return finishMeasured(
                outcome: .alreadyRunning,
                t0: t0, t1: t0, t2: t0, t3: t0, t4: t0, t5: clock.nowNanoseconds(),
                total: 0, eligible: 0, skipped: 0, skipReasons: [:], attempted: 0, succeeded: 0, failed: 0,
                verified: false, timedOut: false
            )
        }
        isRunning = true
        defer { isRunning = false }
        latestSuccessfulWindowMoves = []
        latestFocusedMoveRoute = nil

        guard authorization.isTrusted else {
            lastDiagnostics = .empty
            let now = clock.nowNanoseconds()
            return finishMeasured(
                outcome: .noPermission,
                t0: t0, t1: now, t2: now, t3: now, t4: now, t5: now,
                total: 0, eligible: 0, skipped: 0, skipReasons: [:], attempted: 0, succeeded: 0, failed: 0,
                verified: false, timedOut: false
            )
        }

        if hasPendingReturn && !callReturn {
            lastDiagnostics = .empty
            let now = clock.nowNanoseconds()
            return finishMeasured(outcome: .noMoves, t0: t0, t1: now, t2: now, t3: now, t4: now, t5: now,
                total: 0, eligible: 0, skipped: 0, skipReasons: [:], attempted: 0, succeeded: 0, failed: 0,
                verified: false, timedOut: false)
        }

        let currentDisplays: [DisplaySnapshot]
        do {
            currentDisplays = try displays.currentDisplays()
        } catch {
            lastDiagnostics = .empty
            let now = clock.nowNanoseconds()
            return finishMeasured(
                outcome: .unsupportedDisplayCount(0),
                t0: t0, t1: now, t2: now, t3: now, t4: now, t5: now,
                total: 0, eligible: 0, skipped: 0, skipReasons: [:], attempted: 0, succeeded: 0, failed: 0,
                verified: false, timedOut: false
            )
        }
        guard currentDisplays.count >= 2 else {
            lastDiagnostics = .empty
            let now = clock.nowNanoseconds()
            return finishMeasured(
                outcome: .unsupportedDisplayCount(currentDisplays.count),
                t0: t0, t1: now, t2: now, t3: now, t4: now, t5: now,
                total: 0, eligible: 0, skipped: 0, skipReasons: [:], attempted: 0, succeeded: 0, failed: 0,
                verified: false, timedOut: false
            )
        }

        guard let (displayA, displayB) = frozenPair(from: currentDisplays) else {
            lastDiagnostics = .empty
            let now = clock.nowNanoseconds()
            return finishMeasured(
                outcome: .unsupportedDisplayCount(currentDisplays.count),
                t0: t0, t1: now, t2: now, t3: now, t4: now, t5: now,
                total: 0, eligible: 0, skipped: 0, skipReasons: [:], attempted: 0, succeeded: 0, failed: 0,
                verified: false, timedOut: false
            )
        }
        let batch = capture(activeDisplays: currentDisplays, selectedDisplays: [displayA, displayB])
        latestPreSwapSnapshots = batch.windows.map(\.snapshot)
        guard topologyMatches(currentDisplays) else {
            let now = clock.nowNanoseconds()
            lastDiagnostics = topologyChangedDiagnostics(batch: batch, displayA: displayA, displayB: displayB)
            return finishMeasured(
                outcome: .displayTopologyChanged,
                t0: t0, t1: now, t2: now, t3: now, t4: now, t5: now,
                total: batch.totalWindows, eligible: batch.windows.count, skipped: batch.skipped.count,
                skipReasons: lastDiagnostics.skippedByReason, attempted: 0, succeeded: 0, failed: 0,
                verified: false, timedOut: false
            )
        }
        selection?.reconcile(batch.knownRuntimeKeys)
        let t1 = clock.nowNanoseconds()
        let selectedKeys = selection?.frozenSelectedKeys()
        var selectedWindows = batch.windows.filter { window in
            guard window.presentationState.isFullScreen != true else { return false }
            if let focusedWindowKey { return window.runtimeKey == focusedWindowKey }
            guard let selectedKeys else { return true }
            return window.runtimeKey.map { selectedKeys.contains($0) } ?? true
        }
        let returning = callReturn && calledWindow != nil
        var newCall: CalledWindow?
        if callReturn {
            let primaryID = (displays as? any PrimaryDisplayProviding)?.primaryDisplayID()
                ?? currentDisplays.map(\.id).min() ?? 0
            let pairIDs: Set<UInt32> = [displayA.id, displayB.id]
            let eligible = batch.windows.filter {
                $0.presentationState.isFullScreen != true && $0.runtimeKey != nil &&
                pairIDs.contains($0.snapshot.sourceDisplayID) &&
                !WindowInventoryClassifier.spans($0.originalFrame, displays: currentDisplays)
            }
            if let saved = calledWindow {
                // A changed pair or disconnected source never reroutes a Return.
                selectedWindows = pairIDs == Set([saved.sourceDisplayID, saved.primaryDisplayID])
                    ? eligible.filter { $0.runtimeKey == saved.key } : []
            } else {
                selectedWindows = pairIDs.contains(primaryID)
                    ? Array(eligible.filter { $0.snapshot.sourceDisplayID != primaryID && $0.stackingOrder != nil }
                        .sorted { $0.stackingOrder! < $1.stackingOrder! }.prefix(1)) : []
                if let window = selectedWindows.first, let key = window.runtimeKey {
                    newCall = CalledWindow(key: key, sourceDisplayID: window.snapshot.sourceDisplayID,
                        primaryDisplayID: primaryID, originalFrame: window.originalFrame, verified: false)
                }
            }
        }
        if !callReturn && focusedWindowKey == nil && selectedKeys != nil && selectedWindows.isEmpty && batch.windows.contains(where: { $0.presentationState.isFullScreen != true }) {
            let now = clock.nowNanoseconds()
            lastDiagnostics = makeDiagnostics(
                batch: batch,
                selectedWindows: [],
                moves: [],
                displayA: displayA,
                displayB: displayB,
                attempted: 0,
                succeeded: 0,
                failed: 0
            )
            return finishMeasured(outcome: .noSelection, t0: t0, t1: t1, t2: now, t3: now, t4: now, t5: now,
                total: batch.totalWindows, eligible: batch.windows.count, skipped: batch.skipped.count,
                skipReasons: [:], attempted: 0, succeeded: 0, failed: 0, verified: false, timedOut: false)
        }
        let snapshots = selectedWindows.map(\.snapshot)
        let selectedIDs = Set(snapshots.map(\.id))
        let moves: [WindowMove]
        if returning, let saved = calledWindow, let window = selectedWindows.first,
           let destination = currentDisplays.first(where: { $0.id == saved.sourceDisplayID }) {
            let frame: CGRect
            if window.isResizable {
                frame = WindowMappingEngine().clamp(frame: saved.originalFrame, to: destination.visibleFrame)
            } else {
                let size = window.originalFrame.size
                frame = CGRect(x: min(max(saved.originalFrame.minX, destination.visibleFrame.minX), destination.visibleFrame.maxX - size.width),
                    y: min(max(saved.originalFrame.minY, destination.visibleFrame.minY), destination.visibleFrame.maxY - size.height),
                    width: size.width, height: size.height)
            }
            // An oversized fixed-size window cannot safely fit after a display change.
            moves = destination.visibleFrame.contains(frame)
                ? [WindowMove(windowID: window.snapshot.id, destinationDisplayID: destination.id, frame: frame)] : []
        } else {
            moves = planner.makeSwapMoves(windows: snapshots, displayA: displayA, displayB: displayB)
                .filter { selectedIDs.contains($0.windowID) }
                .compactMap { move in
                    guard callReturn, let window = selectedWindows.first, !window.isResizable,
                          let destination = currentDisplays.first(where: { $0.id == move.destinationDisplayID }) else { return move }
                    let size = window.originalFrame.size
                    let visible = destination.visibleFrame
                    guard size.width <= visible.width, size.height <= visible.height else { return nil }
                    let frame = CGRect(x: min(max(move.frame.minX, visible.minX), visible.maxX - size.width),
                        y: min(max(move.frame.minY, visible.minY), visible.maxY - size.height),
                        width: size.width, height: size.height)
                    return WindowMove(windowID: move.windowID, destinationDisplayID: move.destinationDisplayID, frame: frame)
                }
        }
        let orderedMoves = moves
        let t2 = clock.nowNanoseconds()
        let capabilities = Dictionary(uniqueKeysWithValues: batch.windows.map { ($0.snapshot.id, $0.isResizable) })

        guard topologyMatches(currentDisplays) else {
            let now = clock.nowNanoseconds()
            lastDiagnostics = makeDiagnostics(
                batch: batch,
                selectedWindows: selectedWindows,
                moves: moves,
                displayA: displayA,
                displayB: displayB,
                attempted: 0,
                succeeded: 0,
                failed: 0
            )
            return finishMeasured(
                outcome: .displayTopologyChanged,
                t0: t0, t1: t1, t2: t2, t3: now, t4: now, t5: now,
                total: lastDiagnostics.discovered, eligible: lastDiagnostics.eligible,
                skipped: lastDiagnostics.skippedByReason.values.reduce(0, +), skipReasons: lastDiagnostics.skippedByReason,
                attempted: 0, succeeded: 0, failed: 0, verified: false, timedOut: false
            )
        }

        let t3 = clock.nowNanoseconds()
        if callReturn, !moves.isEmpty, let newCall { calledWindow = newCall }
        var applyFailedIDs = Set<WindowID>()
        var verifiedCandidates: [(WindowMove, Bool)] = []
        for move in orderedMoves {
            guard let isResizable = capabilities[move.windowID] else {
                applyFailedIDs.insert(move.windowID)
                continue
            }
            if windowApplying.apply(move: move, isResizable: isResizable).succeeded {
                if callReturn, let raising = windowApplying as? any WindowRaising,
                   !raising.raise(windowID: move.windowID).succeeded {
                    applyFailedIDs.insert(move.windowID)
                }
                verifiedCandidates.append((move, isResizable))
            } else {
                applyFailedIDs.insert(move.windowID)
            }
        }
        // T4 measures only the final planned AX move command, never recovery
        // or verification work.
        let t4 = clock.nowNanoseconds()
        let initialStatuses = verificationStatuses(verifiedCandidates)
        var statusesForVerification = initialStatuses
        if let windowVisibilityRecoverer, windowVerifier != nil {
            let hiddenCandidates = verifiedCandidates.filter {
                initialStatuses[$0.0.windowID] == .notVisible
            }
            for (move, isResizable) in hiddenCandidates {
                _ = windowVisibilityRecoverer.recoverVisibility(for: move, isResizable: isResizable, knownStatus: .notVisible)
            }
            if !hiddenCandidates.isEmpty {
                let postRaiseStatuses = verificationStatuses(verifiedCandidates)
                for (move, isResizable) in hiddenCandidates where postRaiseStatuses[move.windowID] == .pending {
                    if !windowApplying.apply(move: move, isResizable: isResizable).succeeded {
                        applyFailedIDs.insert(move.windowID)
                    }
                }
                statusesForVerification = hiddenCandidates.contains { postRaiseStatuses[$0.0.windowID] == .pending }
                    ? [:]
                    : postRaiseStatuses
            }
        }

        let verification = await verify(
            verifiedCandidates,
            initialStatuses: statusesForVerification,
            deadlineNanoseconds: t4 &+ 500_000_000
        )
        for id in verification.notVisibleIDs {
            guard let isResizable = capabilities[id] else { continue }
            _ = windowRestorer?.restore(windowID: id, isResizable: isResizable)
        }
        let t5 = clock.nowNanoseconds()
        let failedIDs = applyFailedIDs.union(verification.unverifiedIDs)
        if callReturn, !moves.isEmpty, failedIDs.isEmpty {
            if returning { calledWindow = nil }
            else { calledWindow?.verified = true }
        }
        if focusedWindowKey != nil,
           let move = moves.first, !failedIDs.contains(move.windowID),
           let sourceID = snapshots.first(where: { $0.id == move.windowID })?.sourceDisplayID,
           let source = currentDisplays.first(where: { $0.id == sourceID }),
           let destination = currentDisplays.first(where: { $0.id == move.destinationDisplayID }) {
            latestFocusedMoveRoute = (source, destination)
        }
        latestSuccessfulWindowMoves = successfulWindowMoves(
            batch: batch,
            moves: moves,
            failedIDs: failedIDs
        )
        let succeeded = moves.count - failedIDs.count
        let failed = failedIDs.count
        lastDiagnostics = makeDiagnostics(
            batch: batch,
            selectedWindows: selectedWindows,
            moves: moves,
            displayA: displayA,
            displayB: displayB,
            attempted: moves.count,
            succeeded: succeeded,
            failed: failed
        )
        let outcome: SwapOutcome = failed == 0
            ? (moves.isEmpty ? .noMoves : .success(attempted: moves.count, succeeded: succeeded))
            : .partialFailure(attempted: moves.count, succeeded: succeeded, failed: failed)
        return finishMeasured(
            outcome: outcome,
            t0: t0, t1: t1, t2: t2, t3: t3, t4: t4, t5: t5,
            total: lastDiagnostics.discovered, eligible: lastDiagnostics.eligible,
            skipped: lastDiagnostics.skippedByReason.values.reduce(0, +), skipReasons: lastDiagnostics.skippedByReason,
            attempted: moves.count, succeeded: succeeded, failed: failed,
            verified: !moves.isEmpty && failed == 0 && verification.didVerify, timedOut: verification.timedOut
        )
    }

    private func successfulWindowMoves(
        batch: WindowCaptureBatch,
        moves: [WindowMove],
        failedIDs: Set<WindowID>
    ) -> [SuccessfulWindowMove] {
        let runtimeKeysByWindowID = batch.windows.reduce(into: [WindowID: RuntimeWindowKey]()) { keys, window in
            if let runtimeKey = window.runtimeKey {
                keys[window.snapshot.id] = runtimeKey
            }
        }
        return moves.compactMap { move in
            guard !failedIDs.contains(move.windowID),
                  let runtimeKey = runtimeKeysByWindowID[move.windowID] else { return nil }
            return SuccessfulWindowMove(
                runtimeKey: runtimeKey,
                destinationDisplayID: move.destinationDisplayID
            )
        }
    }

    /// Selects exactly two displays once per transaction. The returned values
    /// are held locally, so later menu changes cannot reroute in-flight moves.
    private func frozenPair(from activeDisplays: [DisplaySnapshot]) -> (DisplaySnapshot, DisplaySnapshot)? {
        let primaryDisplayID = (displays as? any PrimaryDisplayProviding)?.primaryDisplayID()
            ?? activeDisplays.map(\.id).min()
            ?? 0
        let candidateCounts: [UInt32: Int]
        if activeDisplays.count > 2 {
            candidateCounts = (windowProvider as? any DisplayCandidateCounting)?
                .candidateCounts(activeDisplays: activeDisplays) ?? [:]
        } else {
            candidateCounts = [:]
        }
        displaySelection.reconcile(
            activeDisplays: activeDisplays,
            primaryDisplayID: primaryDisplayID,
            candidateCounts: candidateCounts
        )
        let ids = displaySelection.frozenPair()
        guard ids.count == 2,
              let displayA = activeDisplays.first(where: { $0.id == ids[0] }),
              let displayB = activeDisplays.first(where: { $0.id == ids[1] }) else {
            return nil
        }
        return (displayA, displayB)
    }

    private func capture(
        activeDisplays: [DisplaySnapshot],
        selectedDisplays: [DisplaySnapshot]
    ) -> WindowCaptureBatch {
        if let pairProvider = windowProvider as? any DisplayPairWindowProviding {
            return pairProvider.captureWindows(
                activeDisplays: activeDisplays,
                selectedDisplays: selectedDisplays
            )
        }
        // Compatibility seam for lightweight fakes and third-party adapters.
        // The live service always receives the complete topology above.
        return windowProvider.captureWindows(displays: selectedDisplays)
    }

    private func topologyMatches(_ transactionDisplays: [DisplaySnapshot]) -> Bool {
        guard let latestDisplays = try? displays.currentDisplays() else { return false }
        return transactionDisplays.sorted { $0.id < $1.id } ==
            latestDisplays.sorted { $0.id < $1.id }
    }

    private func topologyChangedDiagnostics(
        batch: WindowCaptureBatch,
        displayA: DisplaySnapshot,
        displayB: DisplaySnapshot
    ) -> SwapDiagnostics {
        makeDiagnostics(
            batch: batch,
            selectedWindows: [],
            moves: [],
            displayA: displayA,
            displayB: displayB,
            attempted: 0,
            succeeded: 0,
            failed: 0
        )
    }

    private func verificationStatuses(_ candidates: [(WindowMove, Bool)]) -> [WindowID: WindowVerificationStatus] {
        guard let windowVerifier else { return [:] }
        if let batchVerifier = windowVerifier as? any WindowBatchVerifying {
            return batchVerifier.verificationStatuses(for: candidates, tolerance: 2)
        }
        return Dictionary(uniqueKeysWithValues: candidates.map { ($0.0.windowID, windowVerifier.verificationStatus(for: $0.0, isResizable: $0.1, tolerance: 2)) })
    }

    private func verify(
        _ candidates: [(WindowMove, Bool)],
        initialStatuses: [WindowID: WindowVerificationStatus] = [:],
        deadlineNanoseconds: UInt64? = nil
    ) async -> (unverifiedIDs: Set<WindowID>, notVisibleIDs: Set<WindowID>, didVerify: Bool, timedOut: Bool) {
        guard !candidates.isEmpty else { return ([], [], windowVerifier != nil, false) }
        guard windowVerifier != nil else { return (Set(candidates.map { $0.0.windowID }), [], false, false) }
        let allCandidates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.0.windowID, $0) })
        var latestStatuses = initialStatuses
        let deadline = deadlineNanoseconds ?? (clock.nowNanoseconds() &+ 500_000_000)
        while true {
            let statuses = latestStatuses.isEmpty ? verificationStatuses(candidates) : latestStatuses
            latestStatuses = [:]
            let unresolved = Set(allCandidates.compactMap { id, _ in
                let status = statuses[id] ?? .unavailable
                latestStatuses[id] = status
                return status == .verified ? nil : id
            }
            )
            guard !unresolved.isEmpty else { return ([], [], true, false) }
            guard clock.nowNanoseconds() < deadline else {
                let notVisible = Set(latestStatuses.compactMap { $0.value == .notVisible ? $0.key : nil })
                    .intersection(unresolved)
                return (unresolved, notVisible, true, true)
            }
            latestStatuses = [:]
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func finishMeasured(
        outcome: SwapOutcome,
        t0: UInt64, t1: UInt64, t2: UInt64, t3: UInt64, t4: UInt64, t5: UInt64,
        total: Int, eligible: Int, skipped: Int, skipReasons: [String: Int], attempted: Int, succeeded: Int, failed: Int,
        verified: Bool, timedOut: Bool
    ) -> MeasuredSwapResult {
        let record = SwapPerformanceRecord(
            operationID: UUID().uuidString,
            outcome: outcome.diagnosticLabel,
            commandReceivedNanoseconds: t0,
            windowsDiscoveredNanoseconds: t1,
            targetFramesCalculatedNanoseconds: t2,
            firstWindowMoveStartedNanoseconds: t3,
            lastWindowMoveCommandCompletedNanoseconds: t4,
            finalStateVerifiedNanoseconds: t5,
            windowsTotal: total,
            windowsEligible: eligible,
            windowsSkipped: skipped,
            skipReasons: skipReasons,
            planned: lastDiagnostics.planned,
            attempted: attempted,
            succeeded: succeeded,
            failed: failed,
            verificationSucceeded: verified,
            verificationTimedOut: timedOut
        )
        performanceRecorder?.record(record)
        return MeasuredSwapResult(outcome: outcome, performance: record)
    }

    private func skipReason(for snapshot: WindowSnapshot, displayA: DisplaySnapshot, displayB: DisplaySnapshot) -> WindowSkipReason {
        let frame = snapshot.frame
        let intersectsA = frame.intersection(displayA.frame)
        let intersectsB = frame.intersection(displayB.frame)
        if !intersectsA.isNull && intersectsA.width > 0 && intersectsA.height > 0 &&
            !intersectsB.isNull && intersectsB.width > 0 && intersectsB.height > 0 {
            return .spanningDisplays
        }
        return .unknownSourceDisplay
    }

    private func makeDiagnostics(
        batch: WindowCaptureBatch,
        selectedWindows: [CapturedWindow],
        moves: [WindowMove],
        displayA: DisplaySnapshot,
        displayB: DisplaySnapshot,
        attempted: Int,
        succeeded: Int,
        failed: Int
    ) -> SwapDiagnostics {
        let plannedIDs = Set(moves.map(\.windowID))
        // Only selected windows reached the planner. An unchecked ordinary
        // window is an intentional user choice, never an unknown-source or
        // planner failure in diagnostics.
        let plannerSkipReasons = selectedWindows
            .filter { !plannedIDs.contains($0.snapshot.id) }
            .map { skipReason(for: $0.snapshot, displayA: displayA, displayB: displayB) }
        let allSkipReasons = batch.skipped.map(\.reason) + plannerSkipReasons
        var skipReasonCounts = allSkipReasons.reduce(into: [String: Int]()) { counts, reason in
            counts[reason.rawValue, default: 0] += 1
        }
        for failure in batch.failures {
            let reason: String?
            switch failure.kind {
            case .applicationEnumeration:
                reason = "applicationEnumeration"
            case .visibleWindowEnumeration:
                reason = "visibleWindowEnumeration"
            case .windowEnumeration:
                reason = "windowEnumeration"
            case .attributes:
                reason = nil
            }
            if let reason {
                skipReasonCounts[reason, default: 0] += 1
            }
        }
        return SwapDiagnostics(
            discovered: batch.totalWindows,
            eligible: batch.windows.count,
            selected: selectedWindows.count,
            skippedByReason: skipReasonCounts,
            planned: moves.count,
            attempted: attempted,
            succeeded: succeeded,
            failed: failed
        )
    }
}
