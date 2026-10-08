import CoreGraphics
import ScreenSwapCore
import Testing
@testable import ScreenSwapMac

@MainActor
private final class EventLog {
    var events: [String] = []
}

@MainActor
private final class FakeAuthorizer: AccessibilityAuthorizing {
    var trusted: Bool
    var requestCount = 0
    var onTrust: (() -> Void)?
    private var didInvokeTrustCallback = false
    let log: EventLog?

    init(trusted: Bool, log: EventLog? = nil) {
        self.trusted = trusted
        self.log = log
    }

    var isTrusted: Bool {
        log?.events.append("trust")
        if !didInvokeTrustCallback {
            didInvokeTrustCallback = true
            onTrust?()
        }
        return trusted
    }

    func requestAccess() {
        requestCount += 1
    }
}

@MainActor
private final class FakeDisplays: DisplayProviding {
    var values: [DisplaySnapshot]
    let log: EventLog?

    init(_ values: [DisplaySnapshot], log: EventLog? = nil) {
        self.values = values
        self.log = log
    }

    func currentDisplays() throws -> [DisplaySnapshot] {
        log?.events.append("displays")
        return values
    }
}

@MainActor
private final class FakeWindows: WindowProviding, WindowApplying {
    var batch: WindowCaptureBatch
    var applied: [(WindowMove, Bool)] = []
    var results: [WindowApplyResult]
    let log: EventLog?

    init(batch: WindowCaptureBatch = WindowCaptureBatch(windows: []), results: [WindowApplyResult] = [], log: EventLog? = nil) {
        self.batch = batch
        self.results = results
        self.log = log
    }

    func captureWindows(displays: [DisplaySnapshot]) -> WindowCaptureBatch {
        log?.events.append("capture")
        return batch
    }

    func apply(move: WindowMove, isResizable: Bool) -> WindowApplyResult {
        log?.events.append("apply")
        applied.append((move, isResizable))
        return results.isEmpty ? .success : results.removeFirst()
    }
}

@MainActor
private final class PairAwareFakeWindows: DisplayPairWindowProviding, WindowApplying, DisplayCandidateCounting {
    let allWindows: [CapturedWindow]
    let candidates: [UInt32: Int]
    var applied: [(WindowMove, Bool)] = []
    private(set) var selectedDisplayIDs: [UInt32] = []
    var onCapture: (() -> Void)?

    init(allWindows: [CapturedWindow], candidates: [UInt32: Int]) {
        self.allWindows = allWindows
        self.candidates = candidates
    }

    func captureWindows(displays: [DisplaySnapshot]) -> WindowCaptureBatch {
        WindowCaptureBatch(windows: allWindows)
    }

    func captureWindows(activeDisplays: [DisplaySnapshot], selectedDisplays: [DisplaySnapshot]) -> WindowCaptureBatch {
        selectedDisplayIDs = selectedDisplays.map(\.id)
        let selected = Set(selectedDisplayIDs)
        let windows = allWindows.filter { selected.contains($0.snapshot.sourceDisplayID) }
        let skipped = allWindows.compactMap { window -> WindowSkip? in
            selected.contains(window.snapshot.sourceDisplayID)
                ? nil
                : WindowSkip(processIdentifier: window.snapshot.id.processIdentifier, reason: .unselectedDisplay)
        }
        let batch = WindowCaptureBatch(
            windows: windows,
            skipped: skipped,
            knownRuntimeKeys: Set(allWindows.compactMap(\.runtimeKey))
        )
        onCapture?()
        return batch
    }

    func candidateCounts(activeDisplays: [DisplaySnapshot]) -> [UInt32: Int] { candidates }

    func apply(move: WindowMove, isResizable: Bool) -> WindowApplyResult {
        applied.append((move, isResizable))
        return .success
    }
}

@MainActor
private final class FakeNotVisibleVerifier: WindowVerifying {
    let clock: RollbackClock

    init(clock: RollbackClock) {
        self.clock = clock
    }

    func verificationStatus(for move: WindowMove, isResizable: Bool, tolerance: CGFloat) -> WindowVerificationStatus {
        clock.value = 500_000_000
        return .notVisible
    }
}

@MainActor
private final class RollbackClock: MonotonicTimeSource {
    var value: UInt64 = 0
    func nowNanoseconds() -> UInt64 { value }
}

@MainActor
private final class FakeRestorer: WindowRestoring {
    var restored: [(WindowID, Bool)] = []

    func restore(windowID: WindowID, isResizable: Bool) -> WindowApplyResult {
        restored.append((windowID, isResizable))
        return .success
    }
}

@MainActor
private final class CountingBatchVerifier: WindowBatchVerifying {
    var rounds: [[WindowID: WindowVerificationStatus]]
    var calls = 0
    var candidatesPerRound: [Int] = []

    init(rounds: [[WindowID: WindowVerificationStatus]]) { self.rounds = rounds }

    func verificationStatus(for move: WindowMove, isResizable: Bool, tolerance: CGFloat) -> WindowVerificationStatus { .unavailable }

    func verificationStatuses(for candidates: [(WindowMove, Bool)], tolerance: CGFloat) -> [WindowID: WindowVerificationStatus] {
        candidatesPerRound.append(candidates.count)
        defer { calls += 1 }
        return rounds[min(calls, rounds.count - 1)]
    }
}

@MainActor
private final class CountingRecoverer: WindowVisibilityRecovering {
    var legacyCalls = 0
    var knownStatusCalls = 0
    func recoverVisibility(for move: WindowMove, isResizable: Bool) -> WindowApplyResult { legacyCalls += 1; return .success }
    func recoverVisibility(for move: WindowMove, isResizable: Bool, knownStatus: WindowVerificationStatus) -> WindowApplyResult {
        knownStatusCalls += 1
        return .success
    }
}

@MainActor
private final class FakePlanner: SwapPlanning {
    let log: EventLog
    let moves: [WindowMove]
    private(set) var plannedWindows: [WindowSnapshot] = []
    var onPlan: (() -> Void)?

    init(log: EventLog, moves: [WindowMove]) {
        self.log = log
        self.moves = moves
    }

    func makeSwapMoves(windows: [WindowSnapshot], displayA: DisplaySnapshot, displayB: DisplaySnapshot) -> [WindowMove] {
        log.events.append("plan")
        plannedWindows = windows
        onPlan?()
        return moves
    }
}

@Test
@MainActor
func measuredSwapRechecksWholeBatchWithOneSnapshotPerPoll() async {
    let windows = (0..<4).map { captured("poll-\($0)") }
    let moves = windows.map { WindowMove(windowID: $0.snapshot.id, destinationDisplayID: 2, frame: $0.snapshot.frame) }
    let first = Dictionary(uniqueKeysWithValues: windows.enumerated().map { index, window in
        (window.snapshot.id, index == 3 ? WindowVerificationStatus.pending : .verified)
    })
    let verifier = CountingBatchVerifier(rounds: [first, first, Dictionary(uniqueKeysWithValues: windows.map { ($0.snapshot.id, .verified) })])
    let provider = FakeWindows(batch: WindowCaptureBatch(windows: windows))
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true), displays: FakeDisplays(displays(count: 2)),
        windowProvider: provider, windowApplying: provider,
        planner: FakePlanner(log: EventLog(), moves: moves), windowVerifier: verifier
    )

    #expect((await coordinator.swapMeasured()).outcome == .success(attempted: 4, succeeded: 4))
    #expect(verifier.calls == 3)
    #expect(verifier.candidatesPerRound == [4, 4, 4])
}

@Test
@MainActor
func measuredSwapReappliesOnceWhenRaiseChangesGeometry() async {
    let window = captured("raised-window")
    let move = WindowMove(windowID: window.snapshot.id, destinationDisplayID: 2, frame: window.snapshot.frame)
    let verifier = CountingBatchVerifier(rounds: [
        [window.snapshot.id: .notVisible], [window.snapshot.id: .pending], [window.snapshot.id: .verified]
    ])
    let provider = FakeWindows(batch: WindowCaptureBatch(windows: [window]))
    let recoverer = CountingRecoverer()
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true), displays: FakeDisplays(displays(count: 2)),
        windowProvider: provider, windowApplying: provider,
        planner: FakePlanner(log: EventLog(), moves: [move]), windowVerifier: verifier,
        windowVisibilityRecoverer: recoverer
    )

    #expect((await coordinator.swapMeasured()).outcome == .success(attempted: 1, succeeded: 1))
    #expect(recoverer.knownStatusCalls == 1)
    #expect(recoverer.legacyCalls == 0)
    #expect(provider.applied.count == 2)
}

private func displays(count: Int) -> [DisplaySnapshot] {
    var result: [DisplaySnapshot] = []
    for index in 0..<count {
        let originX = CGFloat(index * 1000)
        result.append(
        DisplaySnapshot(
            id: UInt32(index + 1),
            frame: CGRect(x: originX, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: originX, y: 0, width: 1000, height: 800)
        )
        )
    }
    return result
}

private func captured(
    _ identifier: String,
    resizable: Bool = true,
    presentationState: WindowPresentationState = .unknown,
    runtimeKey: RuntimeWindowKey? = nil
) -> CapturedWindow {
    CapturedWindow(
        snapshot: WindowSnapshot(
            id: WindowID(processIdentifier: 10, accessibilityIdentifier: identifier),
            sourceDisplayID: 1,
            frame: CGRect(x: 100, y: 100, width: 300, height: 200)
        ),
        isResizable: resizable,
        presentationState: presentationState,
        runtimeKey: runtimeKey
    )
}

@Test
@MainActor
func focusedWindowMoveIgnoresSwapCheckboxAndMovesOnlyItsRuntimeKey() async {
    let firstKey = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 1)
    let secondKey = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 2)
    let first = captured("focused", runtimeKey: firstKey)
    let second = captured("other", runtimeKey: secondKey)
    let store = WindowSelectionStore()
    store.reconcile([firstKey, secondKey])
    store.setSelected(false, for: firstKey)
    let windows = FakeWindows(batch: WindowCaptureBatch(windows: [first, second]))
    let verifier = CountingBatchVerifier(rounds: [[first.snapshot.id: .verified]])
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: FakeDisplays(displays(count: 2)),
        windowProvider: windows,
        windowApplying: windows,
        windowVerifier: verifier,
        selection: store
    )

    let result = await coordinator.moveFocusedWindowMeasured(firstKey)

    #expect(result.outcome == .success(attempted: 1, succeeded: 1))
    #expect(windows.applied.map { $0.0.windowID } == [first.snapshot.id])
    #expect(windows.applied.first?.0.destinationDisplayID == 2)
    #expect(coordinator.latestPreSwapSnapshots.count == 2)
    #expect(!store.isSelected(firstKey))
}

@Test
@MainActor
func focusedWindowMoveRejectsStaleKeyWithoutWrites() async {
    let window = captured("available", runtimeKey: RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 1))
    let windows = FakeWindows(batch: WindowCaptureBatch(windows: [window]))
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: FakeDisplays(displays(count: 2)),
        windowProvider: windows,
        windowApplying: windows
    )

    let result = await coordinator.moveFocusedWindowMeasured(RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 99))

    #expect(result.outcome == .noMoves)
    #expect(windows.applied.isEmpty)
}

@Test
@MainActor
func focusedWindowMoveLeavesUnselectedDisplayUntouched() async {
    let key = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 3)
    let window = CapturedWindow(
        snapshot: WindowSnapshot(
            id: WindowID(processIdentifier: 10, accessibilityIdentifier: "third-display"),
            sourceDisplayID: 3,
            frame: CGRect(x: 2_100, y: 100, width: 300, height: 200)
        ),
        isResizable: true,
        runtimeKey: key
    )
    let windows = FakeWindows(batch: WindowCaptureBatch(windows: [window]))
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: FakeDisplays(displays(count: 3)),
        windowProvider: windows,
        windowApplying: windows
    )

    let result = await coordinator.moveFocusedWindowMeasured(key)

    #expect(result.outcome == .noMoves)
    #expect(windows.applied.isEmpty)
}

@Test
@MainActor
func coordinatorChecksTrustBeforeDisplaysAndWritesNothingWithoutPermission() {
    let log = EventLog()
    let auth = FakeAuthorizer(trusted: false, log: log)
    let windows = FakeWindows(log: log)
    let coordinator = SwapCoordinator(
        authorization: auth,
        displays: FakeDisplays(displays(count: 2), log: log),
        windowProvider: windows,
        windowApplying: windows
    )
    #expect(coordinator.swap() == .noPermission)
    #expect(log.events == ["trust"])
    #expect(windows.applied.isEmpty)
}

@Test
@MainActor
func coordinatorRejectsOnlyFewerThanTwoDisplaysBeforeCapture() {
    for count in [0, 1] {
        let windows = FakeWindows()
        let coordinator = SwapCoordinator(
            authorization: FakeAuthorizer(trusted: true),
            displays: FakeDisplays(displays(count: count)),
            windowProvider: windows,
            windowApplying: windows
        )
        #expect(coordinator.swap() == .unsupportedDisplayCount(count))
        #expect(windows.applied.isEmpty)
    }
}

@Test
@MainActor
func coordinatorSeparatesTrustCapturePlanAndApplyPhases() {
    let log = EventLog()
    let first = captured("first")
    let second = captured("second", resizable: false)
    let windows = FakeWindows(
        batch: WindowCaptureBatch(
            windows: [first, second],
            skipped: [WindowSkip(processIdentifier: 10, reason: .minimized)]
        ),
        log: log
    )
    let moves = [
        WindowMove(windowID: first.snapshot.id, destinationDisplayID: 2, frame: CGRect(x: 1100, y: 100, width: 300, height: 200)),
        WindowMove(windowID: second.snapshot.id, destinationDisplayID: 2, frame: CGRect(x: 1100, y: 100, width: 300, height: 200))
    ]
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true, log: log),
        displays: FakeDisplays(displays(count: 2), log: log),
        windowProvider: windows,
        windowApplying: windows,
        planner: FakePlanner(log: log, moves: moves)
    )
    #expect(coordinator.swap() == .success(attempted: 2, succeeded: 2))
    #expect(log.events == ["trust", "displays", "capture", "displays", "plan", "displays", "apply", "apply"])
    #expect(windows.applied.map(\.1) == [true, false])
    #expect(coordinator.lastDiagnostics == SwapDiagnostics(
        discovered: 3,
        eligible: 2,
        selected: 2,
        skippedByReason: ["minimized": 1],
        planned: 2,
        attempted: 2,
        succeeded: 2,
        failed: 0
    ))
}

@Test
@MainActor
func coordinatorExcludesNativeFullScreenMovesBeforePlanning() {
    let ordinary = captured("ordinary")
    let nativeFullScreen = captured(
        "native-full-screen",
        presentationState: WindowPresentationState(
            isFullScreen: true,
            canToggleFullScreen: true
        )
    )
    let moves = [WindowMove(windowID: ordinary.snapshot.id, destinationDisplayID: 2, frame: .zero)]
    let windows = FakeWindows(
        batch: WindowCaptureBatch(windows: [ordinary, nativeFullScreen])
    )
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: FakeDisplays(displays(count: 2)),
        windowProvider: windows,
        windowApplying: windows,
        planner: FakePlanner(log: EventLog(), moves: moves)
    )

    #expect(coordinator.swap() == .success(attempted: 1, succeeded: 1))
    #expect(windows.applied.map { $0.0.windowID } == [ordinary.snapshot.id])
}

@Test
@MainActor
func coordinatorContinuesAfterAnApplyFailureAndClearsRunningGuard() {
    let firstKey = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 1)
    let secondKey = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 2)
    let first = captured("first", runtimeKey: firstKey)
    let second = captured("second", runtimeKey: secondKey)
    let moves = [
        WindowMove(windowID: first.snapshot.id, destinationDisplayID: 2, frame: .zero),
        WindowMove(windowID: second.snapshot.id, destinationDisplayID: 2, frame: .zero)
    ]
    let windows = FakeWindows(
        batch: WindowCaptureBatch(windows: [first, second]),
        results: [WindowApplyResult(succeeded: false, failure: .position), .success]
    )
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: FakeDisplays(displays(count: 2)),
        windowProvider: windows,
        windowApplying: windows,
        planner: FakePlanner(log: EventLog(), moves: moves)
    )
    #expect(coordinator.swap() == .partialFailure(attempted: 2, succeeded: 1, failed: 1))
    #expect(windows.applied.count == 2)
    #expect(coordinator.latestSuccessfulWindowMoves == [
        SuccessfulWindowMove(runtimeKey: secondKey, destinationDisplayID: 2)
    ])
    #expect(coordinator.swap() == .success(attempted: 2, succeeded: 2))
}

@Test
@MainActor
func coordinatorReturnsAlreadyRunningWhenGuardIsEntered() {
    let auth = FakeAuthorizer(trusted: true)
    let coordinator = SwapCoordinator(
        authorization: auth,
        displays: FakeDisplays(displays(count: 2)),
        windowProvider: FakeWindows(),
        windowApplying: FakeWindows()
    )
    var reentrantResult: SwapOutcome?
    auth.onTrust = { reentrantResult = coordinator.swap() }
    #expect(coordinator.swap() == .noMoves)
    #expect(coordinator.lastDiagnostics == SwapDiagnostics(
        discovered: 0,
        eligible: 0,
        planned: 0,
        attempted: 0,
        succeeded: 0,
        failed: 0
    ))
    #expect(reentrantResult == .alreadyRunning)
}

@Test
@MainActor
func measuredSwapRestoresOnlyWindowsThatRemainNotVisibleAfterVerification() async {
    let runtimeKey = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 99)
    let window = captured("hidden-after-write", resizable: false, runtimeKey: runtimeKey)
    let move = WindowMove(
        windowID: window.snapshot.id,
        destinationDisplayID: 2,
        frame: CGRect(x: 1_100, y: 100, width: 150, height: 100)
    )
    let clock = RollbackClock()
    let restorer = FakeRestorer()
    let windows = FakeWindows(batch: WindowCaptureBatch(windows: [window]))
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: FakeDisplays(displays(count: 2)),
        windowProvider: windows,
        windowApplying: windows,
        windowRestorer: restorer,
        planner: FakePlanner(log: EventLog(), moves: [move]),
        windowVerifier: FakeNotVisibleVerifier(clock: clock),
        clock: clock
    )

    let result = await coordinator.swapMeasured(commandReceivedNanoseconds: 0)
    #expect(result.outcome == .partialFailure(attempted: 1, succeeded: 0, failed: 1))
    #expect(coordinator.latestSuccessfulWindowMoves.isEmpty)
    #expect(restorer.restored.map { $0.0 } == [window.snapshot.id])
    #expect(restorer.restored.map { $0.1 } == [false])
}

@Test
@MainActor
func coordinatorMovesOnlyFrozenSelectedRuntimeKeysAndRetainsCompletePreSwapSnapshot() {
    let firstKey = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 1)
    let secondKey = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 2)
    let first = captured("selected", runtimeKey: firstKey)
    let second = captured("unchecked", runtimeKey: secondKey)
    let store = WindowSelectionStore()
    store.reconcile([firstKey, secondKey])
    store.setSelected(false, for: secondKey)
    let moveFirst = WindowMove(windowID: first.snapshot.id, destinationDisplayID: 2, frame: .zero)
    let moveSecond = WindowMove(windowID: second.snapshot.id, destinationDisplayID: 2, frame: .zero)
    let planner = FakePlanner(log: EventLog(), moves: [moveFirst, moveSecond])
    let windows = FakeWindows(batch: WindowCaptureBatch(windows: [first, second]))
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: FakeDisplays(displays(count: 2)),
        windowProvider: windows,
        windowApplying: windows,
        planner: planner,
        selection: store
    )

    #expect(coordinator.swap() == .success(attempted: 1, succeeded: 1))
    #expect(planner.plannedWindows.map(\.id) == [first.snapshot.id])
    #expect(windows.applied.map { $0.0.windowID } == [first.snapshot.id])
    #expect(coordinator.latestPreSwapSnapshots.map(\.id) == [first.snapshot.id, second.snapshot.id])
    #expect(coordinator.lastDiagnostics == SwapDiagnostics(
        discovered: 2,
        eligible: 2,
        selected: 1,
        planned: 1,
        attempted: 1,
        succeeded: 1,
        failed: 0
    ))
    #expect(coordinator.lastDiagnostics.skippedByReason[WindowSkipReason.unknownSourceDisplay.rawValue] == nil)
}

@Test
@MainActor
func coordinatorReturnsNoSelectionWithoutPlanningOrWriting() {
    let key = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 1)
    let window = captured("unchecked", runtimeKey: key)
    let store = WindowSelectionStore()
    store.reconcile([key])
    store.setSelected(false, for: key)
    let planner = FakePlanner(log: EventLog(), moves: [])
    let windows = FakeWindows(batch: WindowCaptureBatch(windows: [window]))
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: FakeDisplays(displays(count: 2)),
        windowProvider: windows,
        windowApplying: windows,
        planner: planner,
        selection: store
    )

    #expect(coordinator.swap() == .noSelection)
    #expect(planner.plannedWindows.isEmpty)
    #expect(windows.applied.isEmpty)
    #expect(coordinator.lastDiagnostics.planned == 0)
    #expect(coordinator.lastDiagnostics.selected == 0)
    #expect(coordinator.lastDiagnostics.attempted == 0)
    #expect(coordinator.lastDiagnostics.succeeded == 0)
    #expect(coordinator.lastDiagnostics.failed == 0)
}

@Test
@MainActor
func coordinatorReturnsNoMovesForOnlyNativeFullScreenWindow() {
    let window = captured(
        "native-full-screen-without-quartz-key",
        presentationState: WindowPresentationState(isFullScreen: true, canToggleFullScreen: true)
    )
    let planner = FakePlanner(log: EventLog(), moves: [])
    let windows = FakeWindows(batch: WindowCaptureBatch(
        windows: [window],
        skipped: [WindowSkip(processIdentifier: 10, reason: .nativeFullScreenSpace)]
    ))
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: FakeDisplays(displays(count: 2)),
        windowProvider: windows,
        windowApplying: windows,
        planner: planner,
        selection: WindowSelectionStore()
    )

    #expect(coordinator.swap() == .noMoves)
    #expect(planner.plannedWindows.isEmpty)
    #expect(windows.applied.isEmpty)
    #expect(coordinator.lastDiagnostics.selected == 0)
    #expect(coordinator.lastDiagnostics.skippedByReason["nativeFullScreenSpace"] == 1)
}

@Test
@MainActor
func coordinatorDefaultsAWindowFirstSeenAtCaptureToSelected() {
    let key = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 1)
    let window = captured("new-at-capture", runtimeKey: key)
    let move = WindowMove(windowID: window.snapshot.id, destinationDisplayID: 2, frame: .zero)
    let store = WindowSelectionStore()
    let planner = FakePlanner(log: EventLog(), moves: [move])
    let windows = FakeWindows(batch: WindowCaptureBatch(windows: [window]))
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: FakeDisplays(displays(count: 2)),
        windowProvider: windows,
        windowApplying: windows,
        planner: planner,
        selection: store
    )

    #expect(coordinator.swap() == .success(attempted: 1, succeeded: 1))
    #expect(store.isSelected(key))
    #expect(planner.plannedWindows.map(\.id) == [window.snapshot.id])
}

@Test
@MainActor
func coordinatorDoesNotSubstituteAWindowThatAppearsAfterSelectionFreeze() {
    let capturedKey = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 1)
    let laterKey = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 2)
    let window = captured("captured", runtimeKey: capturedKey)
    let move = WindowMove(windowID: window.snapshot.id, destinationDisplayID: 2, frame: .zero)
    let store = WindowSelectionStore()
    let planner = FakePlanner(log: EventLog(), moves: [move])
    planner.onPlan = { store.reconcile([capturedKey, laterKey]) }
    let windows = FakeWindows(batch: WindowCaptureBatch(windows: [window]))
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: FakeDisplays(displays(count: 2)),
        windowProvider: windows,
        windowApplying: windows,
        planner: planner,
        selection: store
    )

    #expect(coordinator.swap() == .success(attempted: 1, succeeded: 1))
    #expect(planner.plannedWindows.map(\.id) == [window.snapshot.id])
    #expect(windows.applied.map { $0.0.windowID } == [window.snapshot.id])
}

@Test
@MainActor
func coordinatorSwapsOnlyFrozenPairWhenThreeDisplaysAreActive() {
    let displayValues = displays(count: 3)
    let pairStore = DisplayPairSelectionStore()
    pairStore.reconcile(
        activeDisplays: displayValues,
        primaryDisplayID: 1,
        candidateCounts: [1: 3, 2: 2, 3: 1]
    )
    pairStore.select(
        displayID: 3,
        activeDisplays: displayValues,
        primaryDisplayID: 1,
        candidateCounts: [1: 3, 2: 2, 3: 1]
    )
    let onFirst = captured("on-first")
    let onSecond = CapturedWindow(
        snapshot: WindowSnapshot(
            id: WindowID(processIdentifier: 10, accessibilityIdentifier: "on-second"),
            sourceDisplayID: 2,
            frame: CGRect(x: 1_100, y: 100, width: 300, height: 200)
        ),
        isResizable: true
    )
    let onThird = CapturedWindow(
        snapshot: WindowSnapshot(
            id: WindowID(processIdentifier: 10, accessibilityIdentifier: "on-third"),
            sourceDisplayID: 3,
            frame: CGRect(x: 2_100, y: 100, width: 300, height: 200)
        ),
        isResizable: true
    )
    let planner = FakePlanner(log: EventLog(), moves: [
        WindowMove(windowID: onFirst.snapshot.id, destinationDisplayID: 3, frame: .zero),
        WindowMove(windowID: onThird.snapshot.id, destinationDisplayID: 1, frame: .zero)
    ])
    let windows = PairAwareFakeWindows(
        allWindows: [onFirst, onSecond, onThird],
        candidates: [1: 3, 2: 2, 3: 1]
    )
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: FakeDisplays(displayValues),
        windowProvider: windows,
        windowApplying: windows,
        planner: planner,
        displaySelection: pairStore
    )

    #expect(coordinator.swap() == .success(attempted: 2, succeeded: 2))
    #expect(windows.selectedDisplayIDs == [1, 3])
    #expect(planner.plannedWindows.map(\.sourceDisplayID).sorted() == [1, 3])
    #expect(!windows.applied.contains { $0.0.windowID == onSecond.snapshot.id })
    #expect(coordinator.lastDiagnostics.skippedByReason[WindowSkipReason.unselectedDisplay.rawValue] == 1)
}

@Test
@MainActor
func coordinatorDoesNotRerouteWhenDisplayPairChangesAfterCapture() {
    let displayValues = displays(count: 3)
    let pairStore = DisplayPairSelectionStore()
    pairStore.reconcile(activeDisplays: displayValues, primaryDisplayID: 1, candidateCounts: [1: 3, 2: 2, 3: 1])
    pairStore.select(displayID: 3, activeDisplays: displayValues, primaryDisplayID: 1, candidateCounts: [1: 3, 2: 2, 3: 1])
    let first = captured("first")
    let third = CapturedWindow(
        snapshot: WindowSnapshot(
            id: WindowID(processIdentifier: 10, accessibilityIdentifier: "third"),
            sourceDisplayID: 3,
            frame: CGRect(x: 2_100, y: 100, width: 300, height: 200)
        ),
        isResizable: true
    )
    let planner = FakePlanner(log: EventLog(), moves: [
        WindowMove(windowID: first.snapshot.id, destinationDisplayID: 3, frame: .zero),
        WindowMove(windowID: third.snapshot.id, destinationDisplayID: 1, frame: .zero)
    ])
    planner.onPlan = {
        pairStore.select(displayID: 2, activeDisplays: displayValues, primaryDisplayID: 1, candidateCounts: [1: 3, 2: 2, 3: 1])
    }
    let windows = PairAwareFakeWindows(allWindows: [first, third], candidates: [1: 3, 2: 2, 3: 1])
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: FakeDisplays(displayValues),
        windowProvider: windows,
        windowApplying: windows,
        planner: planner,
        displaySelection: pairStore
    )

    #expect(coordinator.swap() == .success(attempted: 2, succeeded: 2))
    #expect(windows.selectedDisplayIDs == [1, 3])
    #expect(windows.applied.map { $0.0.destinationDisplayID }.sorted() == [1, 3])
    #expect(pairStore.frozenPair() == [3, 2])
}

@Test
@MainActor
func coordinatorAbortsWithoutWritesWhenSelectedDisplayDisconnectsAfterCapture() {
    let initialDisplays = displays(count: 3)
    let displayProvider = FakeDisplays(initialDisplays)
    let pairStore = DisplayPairSelectionStore()
    pairStore.reconcile(activeDisplays: initialDisplays, primaryDisplayID: 1, candidateCounts: [1: 3, 2: 1, 3: 2])
    pairStore.select(displayID: 3, activeDisplays: initialDisplays, primaryDisplayID: 1, candidateCounts: [1: 3, 2: 1, 3: 2])
    let first = captured("first")
    let third = CapturedWindow(
        snapshot: WindowSnapshot(
            id: WindowID(processIdentifier: 10, accessibilityIdentifier: "third"),
            sourceDisplayID: 3,
            frame: CGRect(x: 2_100, y: 100, width: 300, height: 200)
        ),
        isResizable: true
    )
    let planner = FakePlanner(log: EventLog(), moves: [])
    let windows = PairAwareFakeWindows(allWindows: [first, third], candidates: [1: 3, 2: 1, 3: 2])
    windows.onCapture = { displayProvider.values = Array(initialDisplays.prefix(2)) }
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: displayProvider,
        windowProvider: windows,
        windowApplying: windows,
        planner: planner,
        displaySelection: pairStore
    )

    #expect(coordinator.swap() == .displayTopologyChanged)
    #expect(planner.plannedWindows.isEmpty)
    #expect(windows.applied.isEmpty)
    #expect(coordinator.lastDiagnostics.attempted == 0)
}

@Test
@MainActor
func coordinatorAbortsWithoutWritesWhenDisplayGeometryChangesAfterCapture() {
    let initialDisplays = displays(count: 3)
    let displayProvider = FakeDisplays(initialDisplays)
    let pairStore = DisplayPairSelectionStore()
    pairStore.reconcile(activeDisplays: initialDisplays, primaryDisplayID: 1, candidateCounts: [1: 3, 2: 1, 3: 2])
    pairStore.select(displayID: 3, activeDisplays: initialDisplays, primaryDisplayID: 1, candidateCounts: [1: 3, 2: 1, 3: 2])
    let first = captured("first")
    let third = CapturedWindow(
        snapshot: WindowSnapshot(
            id: WindowID(processIdentifier: 10, accessibilityIdentifier: "third"),
            sourceDisplayID: 3,
            frame: CGRect(x: 2_100, y: 100, width: 300, height: 200)
        ),
        isResizable: true
    )
    let planner = FakePlanner(log: EventLog(), moves: [])
    let windows = PairAwareFakeWindows(allWindows: [first, third], candidates: [1: 3, 2: 1, 3: 2])
    windows.onCapture = {
        var changed = initialDisplays
        changed[2] = DisplaySnapshot(
            id: 3,
            frame: CGRect(x: 2_100, y: 0, width: 900, height: 700),
            visibleFrame: CGRect(x: 2_100, y: 20, width: 900, height: 680)
        )
        displayProvider.values = changed
    }
    let coordinator = SwapCoordinator(
        authorization: FakeAuthorizer(trusted: true),
        displays: displayProvider,
        windowProvider: windows,
        windowApplying: windows,
        planner: planner,
        displaySelection: pairStore
    )

    #expect(coordinator.swap() == .displayTopologyChanged)
    #expect(planner.plannedWindows.isEmpty)
    #expect(windows.applied.isEmpty)
    #expect(coordinator.lastDiagnostics.attempted == 0)
}
