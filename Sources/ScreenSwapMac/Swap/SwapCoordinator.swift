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
    private let planner: any SwapPlanning
    private let clock: any MonotonicTimeSource
    private let performanceRecorder: (any SwapPerformanceRecording)?
    private let selection: (any SwapSelectionProviding)?
    private var isRunning = false
    public private(set) var lastDiagnostics = SwapDiagnostics.empty
    /// Transaction-local AX handles are deliberately not retained. This is the
    /// latest immutable pre-swap geometry snapshot for a future undo action.
    public private(set) var latestPreSwapSnapshots: [WindowSnapshot] = []

    public init(
        authorization: any AccessibilityAuthorizing,
        displays: any DisplayProviding,
        windowProvider: any WindowProviding,
        windowApplying: any WindowApplying,
        windowRestorer: (any WindowRestoring)? = nil,
        planner: any SwapPlanning = WindowMappingEngine(),
        windowVerifier: (any WindowVerifying)? = nil,
        selection: (any SwapSelectionProviding)? = nil,
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
        self.clock = clock
        self.performanceRecorder = performanceRecorder
        self.selection = selection
    }

    public func swap() -> SwapOutcome {
        guard !isRunning else {
            lastDiagnostics = .empty
            return .alreadyRunning
        }
        isRunning = true
        defer { isRunning = false }

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
        guard currentDisplays.count == 2 else {
            lastDiagnostics = .empty
            return .unsupportedDisplayCount(currentDisplays.count)
        }

        let orderedDisplays = currentDisplays.sorted { $0.id < $1.id }
        let displayA = orderedDisplays[0]
        let displayB = orderedDisplays[1]
        let batch = windowProvider.captureWindows(displays: [displayA, displayB])
        latestPreSwapSnapshots = batch.windows.map(\.snapshot)
        selection?.reconcile(Set(batch.windows.compactMap(\.runtimeKey)))
        let selectedKeys = selection?.frozenSelectedKeys()
        let selectedWindows = batch.windows.filter { window in
            guard let selectedKeys else { return true }
            return window.runtimeKey.map { selectedKeys.contains($0) } ?? false
        }
        if selectedKeys != nil && selectedWindows.isEmpty && !batch.windows.isEmpty {
            lastDiagnostics = SwapDiagnostics(discovered: batch.totalWindows, eligible: batch.windows.count)
            return .noSelection
        }
        let snapshots = selectedWindows.map(\.snapshot)
        let selectedIDs = Set(snapshots.map(\.id))
        let moves = planner.makeSwapMoves(
            windows: snapshots,
            displayA: displayA,
            displayB: displayB
        ).filter { selectedIDs.contains($0.windowID) }
        let orderedMoves = movesPrioritizingNativeFullScreen(
            moves,
            capturedWindows: batch.windows
        )
        let capabilities = Dictionary(uniqueKeysWithValues: batch.windows.map { ($0.snapshot.id, $0.isResizable) })

        var attempted = 0
        var succeeded = 0
        for move in orderedMoves {
            attempted += 1
            guard let isResizable = capabilities[move.windowID] else { continue }
            if windowApplying.apply(move: move, isResizable: isResizable).succeeded {
                succeeded += 1
            }
        }

        let failed = attempted - succeeded
        lastDiagnostics = makeDiagnostics(
            batch: batch,
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
        guard currentDisplays.count == 2 else {
            lastDiagnostics = .empty
            let now = clock.nowNanoseconds()
            return finishMeasured(
                outcome: .unsupportedDisplayCount(currentDisplays.count),
                t0: t0, t1: now, t2: now, t3: now, t4: now, t5: now,
                total: 0, eligible: 0, skipped: 0, skipReasons: [:], attempted: 0, succeeded: 0, failed: 0,
                verified: false, timedOut: false
            )
        }

        let orderedDisplays = currentDisplays.sorted { $0.id < $1.id }
        let displayA = orderedDisplays[0]
        let displayB = orderedDisplays[1]
        let batch = windowProvider.captureWindows(displays: [displayA, displayB])
        latestPreSwapSnapshots = batch.windows.map(\.snapshot)
        selection?.reconcile(Set(batch.windows.compactMap(\.runtimeKey)))
        let t1 = clock.nowNanoseconds()
        let selectedKeys = selection?.frozenSelectedKeys()
        let selectedWindows = batch.windows.filter { window in
            guard let selectedKeys else { return true }
            return window.runtimeKey.map { selectedKeys.contains($0) } ?? false
        }
        if selectedKeys != nil && selectedWindows.isEmpty && !batch.windows.isEmpty {
            let now = clock.nowNanoseconds()
            return finishMeasured(outcome: .noSelection, t0: t0, t1: t1, t2: now, t3: now, t4: now, t5: now,
                total: batch.totalWindows, eligible: batch.windows.count, skipped: batch.skipped.count,
                skipReasons: [:], attempted: 0, succeeded: 0, failed: 0, verified: false, timedOut: false)
        }
        let snapshots = selectedWindows.map(\.snapshot)
        let selectedIDs = Set(snapshots.map(\.id))
        let moves = planner.makeSwapMoves(windows: snapshots, displayA: displayA, displayB: displayB)
            .filter { selectedIDs.contains($0.windowID) }
        let orderedMoves = movesPrioritizingNativeFullScreen(
            moves,
            capturedWindows: batch.windows
        )
        let t2 = clock.nowNanoseconds()
        let capabilities = Dictionary(uniqueKeysWithValues: batch.windows.map { ($0.snapshot.id, $0.isResizable) })

        let t3 = clock.nowNanoseconds()
        var applyFailedIDs = Set<WindowID>()
        var verifiedCandidates: [(WindowMove, Bool)] = []
        for move in orderedMoves {
            guard let isResizable = capabilities[move.windowID] else {
                applyFailedIDs.insert(move.windowID)
                continue
            }
            if windowApplying.apply(move: move, isResizable: isResizable).succeeded {
                verifiedCandidates.append((move, isResizable))
            } else {
                applyFailedIDs.insert(move.windowID)
            }
        }
        let t4 = clock.nowNanoseconds()

        let verification = await verify(verifiedCandidates)
        for id in verification.notVisibleIDs {
            guard let isResizable = capabilities[id] else { continue }
            _ = windowRestorer?.restore(windowID: id, isResizable: isResizable)
        }
        let t5 = clock.nowNanoseconds()
        let failedIDs = applyFailedIDs.union(verification.unverifiedIDs)
        let succeeded = moves.count - failedIDs.count
        let failed = failedIDs.count
        lastDiagnostics = makeDiagnostics(
            batch: batch,
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

    private func verify(_ candidates: [(WindowMove, Bool)]) async -> (unverifiedIDs: Set<WindowID>, notVisibleIDs: Set<WindowID>, didVerify: Bool, timedOut: Bool) {
        guard !candidates.isEmpty else { return ([], [], windowVerifier != nil, false) }
        guard let windowVerifier else { return (Set(candidates.map { $0.0.windowID }), [], false, false) }
        var pending = Dictionary(uniqueKeysWithValues: candidates.map { ($0.0.windowID, $0) })
        var latestStatuses: [WindowID: WindowVerificationStatus] = [:]
        let deadline = clock.nowNanoseconds() &+ 500_000_000
        while !pending.isEmpty {
            let verifiedIDs = pending.compactMap { id, candidate in
                let status = windowVerifier.verificationStatus(for: candidate.0, isResizable: candidate.1, tolerance: 2)
                latestStatuses[id] = status
                if status == .verified {
                    return id
                }
                return nil
            }
            for id in verifiedIDs {
                pending.removeValue(forKey: id)
            }
            guard !pending.isEmpty else { return ([], [], true, false) }
            guard clock.nowNanoseconds() < deadline else {
                let unresolved = Set(pending.keys)
                let notVisible = Set(latestStatuses.compactMap { $0.value == .notVisible ? $0.key : nil })
                    .intersection(unresolved)
                return (unresolved, notVisible, true, true)
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return ([], [], true, false)
    }

    /// A native full-screen transition can activate or replace a macOS Space.
    /// Complete those transitions before placing ordinary windows, so a later
    /// Space change cannot hide a window that was already moved to the target
    /// display. Preserve the planner's relative order within each group.
    private func movesPrioritizingNativeFullScreen(
        _ moves: [WindowMove],
        capturedWindows: [CapturedWindow]
    ) -> [WindowMove] {
        let nativeFullScreenIDs = Set(
            capturedWindows.compactMap {
                $0.presentationState.isFullScreen == true ? $0.snapshot.id : nil
            }
        )
        return moves.enumerated()
            .sorted { lhs, rhs in
                let lhsIsNativeFullScreen = nativeFullScreenIDs.contains(lhs.element.windowID)
                let rhsIsNativeFullScreen = nativeFullScreenIDs.contains(rhs.element.windowID)
                if lhsIsNativeFullScreen != rhsIsNativeFullScreen {
                    return lhsIsNativeFullScreen
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
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
        moves: [WindowMove],
        displayA: DisplaySnapshot,
        displayB: DisplaySnapshot,
        attempted: Int,
        succeeded: Int,
        failed: Int
    ) -> SwapDiagnostics {
        let plannedIDs = Set(moves.map(\.windowID))
        let plannerSkipReasons = batch.windows
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
            skippedByReason: skipReasonCounts,
            planned: moves.count,
            attempted: attempted,
            succeeded: succeeded,
            failed: failed
        )
    }
}
