import CoreGraphics
import Foundation
import ScreenSwapCore
import Testing
@testable import ScreenSwapMac

@MainActor
private final class CallAuthorization: AccessibilityAuthorizing {
    var isTrusted = true
    func requestAccess() {}
}

@MainActor
private final class CallDisplays: DisplayProviding, PrimaryDisplayProviding {
    var values: [DisplaySnapshot] = [
        DisplaySnapshot(id: 90, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 775)),
        DisplaySnapshot(id: 3, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 1000, y: 25, width: 1000, height: 775))
    ]
    var calls = 0
    func primaryDisplayID() -> UInt32 { 90 }
    func currentDisplays() throws -> [DisplaySnapshot] { calls += 1; return values }
}

@MainActor
private final class CallWindows: WindowProviding, WindowApplying, WindowVerifying, WindowRaising, WindowRestoring {
    var windows: [CapturedWindow] = []
    var applied: [(WindowMove, Bool)] = []
    var raised: [WindowID] = []
    var restored: [WindowID] = []
    var captures = 0
    var succeeds = true
    var verifies = true
    var raiseSucceeds = true
    var afterCapture: (() -> Void)?
    func captureWindows(displays: [DisplaySnapshot]) -> WindowCaptureBatch {
        captures += 1
        let batch = WindowCaptureBatch(windows: windows)
        afterCapture?()
        return batch
    }
    func apply(move: WindowMove, isResizable: Bool) -> WindowApplyResult {
        applied.append((move, isResizable))
        return succeeds ? .success : WindowApplyResult(succeeded: false, failure: .position)
    }
    func raise(windowID: WindowID) -> WindowApplyResult {
        raised.append(windowID)
        return raiseSucceeds ? .success : WindowApplyResult(succeeded: false, failure: .visibility)
    }
    func restore(windowID: WindowID, isResizable: Bool) -> WindowApplyResult { restored.append(windowID); return .success }
    func verificationStatus(for move: WindowMove, isResizable: Bool, tolerance: CGFloat) -> WindowVerificationStatus {
        verifies ? .verified : .notVisible
    }
}

@MainActor
private final class CallClock: MonotonicTimeSource {
    var value: UInt64 = 0
    func nowNanoseconds() -> UInt64 { defer { value += 600_000_000 }; return value }
}

private func callWindow(_ number: UInt32, on display: UInt32 = 3, rank: Int? = 0,
                        resizable: Bool = true, frame: CGRect? = nil, transaction: String = "capture",
                        fullScreen: Bool = false) -> CapturedWindow {
    CapturedWindow(snapshot: WindowSnapshot(id: WindowID(processIdentifier: 12, accessibilityIdentifier: "\(transaction)-\(number)"),
        sourceDisplayID: display, frame: frame ?? CGRect(x: display == 3 ? 1100 : 100, y: 100, width: 300, height: 200)),
        isResizable: resizable, presentationState: WindowPresentationState(isFullScreen: fullScreen),
        runtimeKey: RuntimeWindowKey(processIdentifier: 12, quartzWindowNumber: number), stackingOrder: rank)
}

@MainActor
private func callCoordinator(_ windows: CallWindows, displays: CallDisplays = CallDisplays(),
                             authorization: CallAuthorization = CallAuthorization(),
                             selection: WindowSelectionStore? = nil, pair: DisplayPairSelectionStore = DisplayPairSelectionStore(),
                             settings: ScreenSwapSettings? = nil) -> SwapCoordinator {
    SwapCoordinator(authorization: authorization, displays: displays, windowProvider: windows,
        windowApplying: windows, windowRestorer: windows, windowVerifier: windows,
        selection: selection, displaySelection: pair, settings: settings, clock: CallClock())
}

@Test @MainActor
func callUsesConfiguredPrimaryAndReturnKeepsOriginalRouteAfterPreferenceChanges() async {
    let suite = "ScreenSwapTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = ScreenSwapSettings(defaults: defaults)
    settings.preferredPrimaryDisplayID = 3
    let windows = CallWindows()
    let source = callWindow(1, on: 90)
    windows.windows = [source, callWindow(2)]
    let coordinator = callCoordinator(windows, settings: settings)
    #expect(await coordinator.callReturnMeasured().outcome == .success(attempted: 1, succeeded: 1))
    #expect(windows.applied.first?.0.windowID == source.snapshot.id)
    #expect(windows.applied.first?.0.destinationDisplayID == 3)
    #expect(windows.applied.first?.0.frame.minX == 1100)
    settings.preferredPrimaryDisplayID = nil
    windows.windows = [callWindow(1, on: 3, transaction: "return")]
    #expect(await coordinator.callReturnMeasured().outcome == .success(attempted: 1, succeeded: 1))
    #expect(windows.applied.last?.0.destinationDisplayID == 90)
    #expect(windows.applied.last?.0.frame == source.originalFrame)
}

@Test @MainActor
func callSelectsPreferredPrimaryOnThreeDisplaysAndFreezesRoleBeforeCapture() async {
    let suite = "ScreenSwapTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = ScreenSwapSettings(defaults: defaults)
    settings.preferredPrimaryDisplayID = 25
    let displays = CallDisplays()
    let thirdFrame = CGRect(x: 2000, y: 0, width: 1000, height: 800)
    displays.values.append(DisplaySnapshot(id: 25, frame: thirdFrame, visibleFrame: thirdFrame))
    let windows = CallWindows()
    windows.windows = [callWindow(1), callWindow(2, on: 90, rank: -1)]
    windows.afterCapture = { settings.preferredPrimaryDisplayID = 90 }
    let coordinator = callCoordinator(windows, displays: displays, settings: settings)
    #expect(await coordinator.callReturnMeasured().outcome == .success(attempted: 1, succeeded: 1))
    // Automatic pair is 25 + stable ID 3; system-primary windows remain untouched.
    #expect(windows.applied.first?.0.windowID == windows.windows[0].snapshot.id)
    #expect(windows.applied.first?.0.destinationDisplayID == 25)
}

@Test @MainActor
func disconnectedPreferredPrimaryFallsBackWithoutErasingPreference() async {
    let suite = "ScreenSwapTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = ScreenSwapSettings(defaults: defaults)
    settings.preferredPrimaryDisplayID = 999
    let windows = CallWindows()
    windows.windows = [callWindow(1)]
    let coordinator = callCoordinator(windows, settings: settings)
    #expect(await coordinator.callReturnMeasured().outcome == .success(attempted: 1, succeeded: 1))
    #expect(windows.applied.first?.0.destinationDisplayID == 90)
    #expect(settings.preferredPrimaryDisplayID == 999)
}

@Test @MainActor
func callUsesQuartzStackingOnSecondaryAndReturnUsesFreshIdentityAndSavedGeometry() async {
    let windows = CallWindows()
    let top = callWindow(2, rank: 1)
    windows.windows = [callWindow(1, rank: 10), callWindow(3, on: 90, rank: 0), top]
    let selection = WindowSelectionStore()
    selection.reconcile(Set(windows.windows.compactMap(\.runtimeKey)))
    selection.setSelected(false, for: top.runtimeKey!)
    let coordinator = callCoordinator(windows, selection: selection)
    let called = await coordinator.callReturnMeasured()
    #expect(called.outcome == .success(attempted: 1, succeeded: 1))
    #expect(windows.applied.map { $0.0.windowID } == [top.snapshot.id])
    #expect(windows.applied.first?.0.destinationDisplayID == 90)
    #expect(windows.raised == [top.snapshot.id])
    #expect(coordinator.latestPreSwapSnapshots.count == 3)
    #expect(coordinator.hasPendingReturn && coordinator.calledWindowIsVerified)
    #expect(!selection.isSelected(top.runtimeKey!))

    // A new AX transaction ID and changed bounds must not replace saved intent.
    let fresh = callWindow(2, on: 90, frame: CGRect(x: 200, y: 200, width: 500, height: 400), transaction: "fresh")
    windows.windows = [callWindow(9, on: 90), fresh]
    let returned = await coordinator.callReturnMeasured()
    #expect(returned.outcome == .success(attempted: 1, succeeded: 1))
    #expect(windows.applied.last?.0.windowID == fresh.snapshot.id)
    #expect(windows.applied.last?.0.destinationDisplayID == 3)
    #expect(windows.applied.last?.0.frame == top.originalFrame)
    #expect(!coordinator.hasPendingReturn)
    #expect(coordinator.latestSuccessfulWindowMoves == [SuccessfulWindowMove(runtimeKey: top.runtimeKey!, destinationDisplayID: 3)])
}

@Test @MainActor
func callReturnBlocksConflictsAndCancelForgetsWithoutMoving() async {
    let windows = CallWindows()
    windows.windows = [callWindow(1)]
    let coordinator = callCoordinator(windows)
    _ = await coordinator.callReturnMeasured()
    let captures = windows.captures
    #expect(coordinator.swap() == .noMoves)
    #expect(await coordinator.swapMeasured().outcome == .noMoves)
    #expect(await coordinator.moveFocusedWindowMeasured(windows.windows[0].runtimeKey!).outcome == .noMoves)
    #expect(windows.captures == captures)
    #expect(windows.applied.count == 1)
    coordinator.cancelCallReturn()
    #expect(!coordinator.hasPendingReturn)
    #expect(windows.applied.count == 1)
    #expect(await coordinator.swapMeasured().outcome == .success(attempted: 1, succeeded: 1))
}

@Test @MainActor
func failedCallAndFailedReturnRetainRecoveryUntilVerifiedReturn() async {
    for failure in 0..<3 {
        let windows = CallWindows()
        windows.windows = [callWindow(1)]
        windows.succeeds = failure != 0
        windows.verifies = failure != 1
        windows.raiseSucceeds = failure != 2
        let coordinator = callCoordinator(windows)
        let result = await coordinator.callReturnMeasured()
        #expect(result.outcome == .partialFailure(attempted: 1, succeeded: 0, failed: 1))
        #expect(coordinator.hasPendingReturn)
        #expect(!coordinator.calledWindowIsVerified)
        if failure == 1 { #expect(windows.restored == [windows.windows[0].snapshot.id]) }
        windows.windows = [callWindow(1, on: 90, transaction: "return")]
        windows.succeeds = false
        #expect(await coordinator.callReturnMeasured().outcome == .partialFailure(attempted: 1, succeeded: 0, failed: 1))
        #expect(coordinator.hasPendingReturn)
        windows.succeeds = true
        windows.verifies = true
        windows.raiseSucceeds = true
        #expect(await coordinator.callReturnMeasured().outcome == .success(attempted: 1, succeeded: 1))
        #expect(!coordinator.hasPendingReturn)
    }
}

@Test @MainActor
func unavailableCalledWindowAndDisconnectedSourceNeverRetargetAnotherWindow() async {
    let windows = CallWindows()
    let displays = CallDisplays()
    windows.windows = [callWindow(1)]
    let coordinator = callCoordinator(windows, displays: displays)
    _ = await coordinator.callReturnMeasured()
    windows.windows = [callWindow(9, on: 90)]
    #expect(await coordinator.callReturnMeasured().outcome == .noMoves)
    #expect(coordinator.hasPendingReturn)
    #expect(windows.applied.count == 1)
    windows.windows = [callWindow(1, on: 90)]
    displays.values.removeAll { $0.id == 3 }
    #expect(await coordinator.callReturnMeasured().outcome == .unsupportedDisplayCount(1))
    #expect(coordinator.hasPendingReturn)
    #expect(windows.applied.count == 1)
}

@Test @MainActor
func callReturnRequiresOriginalPairAndPrimaryMembership() async {
    let windows = CallWindows()
    let displays = CallDisplays()
    let third = DisplaySnapshot(id: 8, frame: CGRect(x: -1000, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: -1000, y: 25, width: 1000, height: 775))
    displays.values.append(third)
    windows.windows = [callWindow(1)]
    let pair = DisplayPairSelectionStore()
    let coordinator = callCoordinator(windows, displays: displays, pair: pair)
    _ = await coordinator.callReturnMeasured()
    #expect(coordinator.hasPendingReturn)
    pair.select(displayID: 8, activeDisplays: displays.values, primaryDisplayID: 90, candidateCounts: [:])
    windows.windows = [callWindow(1, on: 90)]
    #expect(await coordinator.callReturnMeasured().outcome == .noMoves)
    #expect(windows.applied.count == 1)
    coordinator.cancelCallReturn()
    pair.select(displayID: 3, activeDisplays: displays.values, primaryDisplayID: 90, candidateCounts: [8: 10])
    if pair.selectedDisplayIDs.contains(90) {
        pair.select(displayID: 8, activeDisplays: displays.values, primaryDisplayID: 3, candidateCounts: [3: 10])
    }
    // Explicitly selecting two non-primary displays must not silently move to a third display.
    #expect(!pair.selectedDisplayIDs.contains(90))
    windows.windows = [callWindow(1)]
    #expect(await coordinator.callReturnMeasured().outcome == .noMoves)
    #expect(windows.applied.count == 1)
}

@Test @MainActor
func returnClampsSavedFrameAfterDisplayGeometryChangeAndPreservesFixedSize() async {
    for resizable in [true, false] {
        let windows = CallWindows()
        let displays = CallDisplays()
        windows.windows = [callWindow(1, resizable: resizable, frame: CGRect(x: 1650, y: 600, width: 300, height: 150))]
        let coordinator = callCoordinator(windows, displays: displays)
        _ = await coordinator.callReturnMeasured()
        displays.values[1] = DisplaySnapshot(id: 3, frame: CGRect(x: 1000, y: 0, width: 600, height: 500), visibleFrame: CGRect(x: 1000, y: 25, width: 600, height: 475))
        windows.windows = [callWindow(1, on: 90, resizable: resizable, frame: CGRect(x: 100, y: 100, width: 300, height: 150))]
        #expect(await coordinator.callReturnMeasured().outcome == .success(attempted: 1, succeeded: 1))
        #expect(windows.applied.last?.1 == resizable)
        #expect(windows.applied.last?.0.frame == CGRect(x: 1300, y: 350, width: 300, height: 150))
    }
}

@Test @MainActor
func callRejectsFullScreenSpanningAndUnrankedCandidates() async {
    let windows = CallWindows()
    windows.windows = [callWindow(1, fullScreen: true), callWindow(2, rank: nil),
        callWindow(3, frame: CGRect(x: 900, y: 100, width: 300, height: 200))]
    let coordinator = callCoordinator(windows)
    #expect(await coordinator.callReturnMeasured().outcome == .noMoves)
    #expect(!coordinator.hasPendingReturn)
    #expect(windows.applied.isEmpty)
}

@Test @MainActor
func callChecksTrustAndAbortsTopologyChangeBeforeWritingOrRetainingReturn() async {
    let windows = CallWindows()
    let displays = CallDisplays()
    let auth = CallAuthorization()
    auth.isTrusted = false
    windows.windows = [callWindow(1)]
    let coordinator = callCoordinator(windows, displays: displays, authorization: auth)
    #expect(await coordinator.callReturnMeasured().outcome == .noPermission)
    #expect(displays.calls == 0 && windows.captures == 0)
    auth.isTrusted = true
    windows.afterCapture = { displays.values.removeLast() }
    #expect(await coordinator.callReturnMeasured().outcome == .displayTopologyChanged)
    #expect(windows.applied.isEmpty && !coordinator.hasPendingReturn)
}

@Test @MainActor
func oversizedFixedSizeCallIsUnavailableWithoutWrites() async {
    let windows = CallWindows()
    let displays = CallDisplays()
    displays.values[0] = DisplaySnapshot(id: 90, frame: CGRect(x: 0, y: 0, width: 200, height: 800), visibleFrame: CGRect(x: 0, y: 25, width: 200, height: 775))
    windows.windows = [callWindow(1, resizable: false)]
    let coordinator = callCoordinator(windows, displays: displays)
    #expect(await coordinator.callReturnMeasured().outcome == .noMoves)
    #expect(windows.applied.isEmpty && !coordinator.hasPendingReturn)
}

@Test @MainActor
func callReturnFeedbackExplainsToggleAndBlockedRecovery() async {
    let windows = CallWindows()
    let auth = CallAuthorization()
    windows.windows = [callWindow(1)]
    let coordinator = callCoordinator(windows, authorization: auth)
    let handler = StatusItemActionHandler(coordinator: coordinator, authorization: auth)
    #expect(await handler.handleMeasuredCallReturn(commandReceivedNanoseconds: 0) == .success(attempted: 1, succeeded: 1))
    #expect(handler.feedback.title == "Window called")
    #expect(handler.tooltip.contains("primary display"))
    #expect(await handler.handleMeasuredClick(commandReceivedNanoseconds: 0) == .noMoves)
    #expect(handler.feedback.title == "Return pending")
    windows.windows = [callWindow(9, on: 90)]
    #expect(await handler.handleMeasuredCallReturn(commandReceivedNanoseconds: 0) == .noMoves)
    #expect(handler.feedback.title == "Return unavailable")
    #expect(handler.feedback.message.contains("Cancel Return"))
    windows.windows = [callWindow(1, on: 90)]
    #expect(await handler.handleMeasuredCallReturn(commandReceivedNanoseconds: 0) == .success(attempted: 1, succeeded: 1))
    #expect(handler.feedback.title == "Window returned")
    #expect(!handler.hasPendingReturn)
}
