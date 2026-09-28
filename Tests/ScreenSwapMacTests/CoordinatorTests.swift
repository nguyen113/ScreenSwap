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
private final class FakePlanner: SwapPlanning {
    let log: EventLog
    let moves: [WindowMove]

    init(log: EventLog, moves: [WindowMove]) {
        self.log = log
        self.moves = moves
    }

    func makeSwapMoves(windows: [WindowSnapshot], displayA: DisplaySnapshot, displayB: DisplaySnapshot) -> [WindowMove] {
        log.events.append("plan")
        return moves
    }
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
    presentationState: WindowPresentationState = .unknown
) -> CapturedWindow {
    CapturedWindow(
        snapshot: WindowSnapshot(
            id: WindowID(processIdentifier: 10, accessibilityIdentifier: identifier),
            sourceDisplayID: 1,
            frame: CGRect(x: 100, y: 100, width: 300, height: 200)
        ),
        isResizable: resizable,
        presentationState: presentationState
    )
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
func coordinatorRejectsEveryUnsupportedDisplayCountBeforeCapture() {
    for count in [0, 1, 3] {
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
    #expect(log.events == ["trust", "displays", "capture", "plan", "apply", "apply"])
    #expect(windows.applied.map(\.1) == [true, false])
    #expect(coordinator.lastDiagnostics == SwapDiagnostics(
        discovered: 3,
        eligible: 2,
        skippedByReason: ["minimized": 1],
        planned: 2,
        attempted: 2,
        succeeded: 2,
        failed: 0
    ))
}

@Test
@MainActor
func coordinatorPrioritizesNativeFullScreenMovesOverPlannerOrder() {
    let ordinary = captured("ordinary")
    let nativeFullScreen = captured(
        "native-full-screen",
        presentationState: WindowPresentationState(
            isFullScreen: true,
            canToggleFullScreen: true
        )
    )
    let moves = [
        WindowMove(windowID: ordinary.snapshot.id, destinationDisplayID: 2, frame: .zero),
        WindowMove(windowID: nativeFullScreen.snapshot.id, destinationDisplayID: 2, frame: .zero)
    ]
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

    #expect(coordinator.swap() == .success(attempted: 2, succeeded: 2))
    #expect(windows.applied.map { $0.0.windowID } == [
        nativeFullScreen.snapshot.id,
        ordinary.snapshot.id
    ])
}

@Test
@MainActor
func coordinatorContinuesAfterAnApplyFailureAndClearsRunningGuard() {
    let first = captured("first")
    let second = captured("second")
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
