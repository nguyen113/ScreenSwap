import CoreGraphics
import Foundation
import ScreenSwapCore
import Testing
@testable import ScreenSwapMac

@MainActor
private final class PerfClock: MonotonicTimeSource {
    var value: UInt64 = 1_000
    func nowNanoseconds() -> UInt64 { value }
    func advance(_ nanoseconds: UInt64) { value += nanoseconds }
}

@MainActor
private final class PerfAuthorizer: AccessibilityAuthorizing {
    var isTrusted: Bool { true }
    func requestAccess() {}
}

@MainActor
private final class PerfDisplays: DisplayProviding {
    let clock: PerfClock
    init(clock: PerfClock) { self.clock = clock }
    func currentDisplays() throws -> [DisplaySnapshot] {
        clock.advance(10_000_000)
        return [
            DisplaySnapshot(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            DisplaySnapshot(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
        ]
    }
}

@MainActor
private final class PerfWindows: WindowProviding, WindowApplying, WindowVerifying {
    let clock: PerfClock
    let window: CapturedWindow
    var verificationCalls = 0
    init(clock: PerfClock) {
        self.clock = clock
        window = CapturedWindow(snapshot: WindowSnapshot(
            id: WindowID(processIdentifier: 7, accessibilityIdentifier: "opaque"),
            sourceDisplayID: 1,
            frame: CGRect(x: 50, y: 50, width: 200, height: 100)
        ), isResizable: true)
    }
    func captureWindows(displays: [DisplaySnapshot]) -> WindowCaptureBatch {
        clock.advance(20_000_000)
        return WindowCaptureBatch(windows: [window], totalWindows: 3, skipped: [
            WindowSkip(processIdentifier: 7, reason: .minimized),
            WindowSkip(processIdentifier: 7, reason: .nonMovable)
        ])
    }
    func apply(move: WindowMove, isResizable: Bool) -> WindowApplyResult {
        clock.advance(30_000_000)
        return .success
    }
    func verificationStatus(for move: WindowMove, isResizable: Bool, tolerance: CGFloat) -> WindowVerificationStatus {
        verificationCalls += 1
        clock.advance(4_000_000)
        return .verified
    }
}

@MainActor
private final class PerfPlanner: SwapPlanning {
    let clock: PerfClock
    init(clock: PerfClock) { self.clock = clock }
    func makeSwapMoves(windows: [WindowSnapshot], displayA: DisplaySnapshot, displayB: DisplaySnapshot) -> [WindowMove] {
        clock.advance(3_000_000)
        return windows.map { WindowMove(windowID: $0.id, destinationDisplayID: displayB.id, frame: CGRect(x: 1_050, y: 50, width: 200, height: 100)) }
    }
}

@MainActor
private final class StoredMeasurements: SwapPerformanceRecording {
    var values: [SwapPerformanceRecord] = []
    func record(_ measurement: SwapPerformanceRecord) { values.append(measurement) }
}

@Test
@MainActor
func measuredSwapCapturesAllTimingPointsAndVerifiesFrames() async {
    let clock = PerfClock()
    let windows = PerfWindows(clock: clock)
    let logger = StoredMeasurements()
    let coordinator = SwapCoordinator(
        authorization: PerfAuthorizer(),
        displays: PerfDisplays(clock: clock),
        windowProvider: windows,
        windowApplying: windows,
        planner: PerfPlanner(clock: clock),
        windowVerifier: windows,
        clock: clock,
        performanceRecorder: logger
    )
    let result = await coordinator.swapMeasured(commandReceivedNanoseconds: clock.nowNanoseconds())
    #expect(result.outcome == .success(attempted: 1, succeeded: 1))
    #expect(result.performance.discoveryNanoseconds == 30_000_000)
    #expect(result.performance.calculationNanoseconds == 3_000_000)
    #expect(result.performance.firstMoveNanoseconds == 33_000_000)
    #expect(result.performance.moveExecutionNanoseconds == 30_000_000)
    #expect(result.performance.verificationNanoseconds == 4_000_000)
    #expect(result.performance.coreLatencyNanoseconds == 63_000_000)
    #expect(result.performance.verifiedLatencyNanoseconds == 67_000_000)
    #expect(result.performance.windowsTotal == 3)
    #expect(result.performance.windowsEligible == 1)
    #expect(result.performance.windowsSkipped == 2)
    #expect(result.performance.skipReasons == ["minimized": 1, "nonMovable": 1])
    #expect(result.performance.outcome == "success")
    #expect(result.performance.planned == 1)
    #expect(result.performance.attempted == 1)
    #expect(result.performance.succeeded == 1)
    #expect(result.performance.failed == 0)
    #expect(result.performance.verificationSucceeded)
    #expect(windows.verificationCalls == 1)
    #expect(logger.values == [result.performance])
}

@MainActor
private final class BenchmarkDriver: SwapBenchmarkDriving {
    var number = 0
    var restoreCalls = 0
    func performMeasuredSwap() async -> MeasuredSwapResult {
        number += 1
        let latency = UInt64(number) * 1_000_000
        return MeasuredSwapResult(outcome: .success(attempted: 1, succeeded: 1), performance: benchmarkRecord(latency: latency))
    }
    func restoreScenario() async -> MeasuredSwapResult {
        restoreCalls += 1
        return MeasuredSwapResult(outcome: .success(attempted: 1, succeeded: 1), performance: benchmarkRecord(latency: 1_000_000))
    }
}

private func benchmarkRecord(latency: UInt64) -> SwapPerformanceRecord {
    SwapPerformanceRecord(
        operationID: UUID().uuidString,
        commandReceivedNanoseconds: 0,
        windowsDiscoveredNanoseconds: 1,
        targetFramesCalculatedNanoseconds: 2,
        firstWindowMoveStartedNanoseconds: latency / 2,
        lastWindowMoveCommandCompletedNanoseconds: latency - 1,
        finalStateVerifiedNanoseconds: latency,
        windowsTotal: 1,
        windowsEligible: 1,
        windowsSkipped: 0,
        attempted: 1,
        succeeded: 1,
        failed: 0,
        verificationSucceeded: true,
        verificationTimedOut: false
    )
}

@Test
@MainActor
func benchmarkExcludesWarmupsExportsStatisticsAndReportsRelativeRegression() async throws {
    let configuration = ScreenSwapBenchmarkConfiguration(scenario: "P01", stageManager: "OFF", warmupRuns: 2, measuredRuns: 10)
    let baseline = ScreenSwapBenchmarkReport(
        configuration: configuration,
        runs: (1...10).map { benchmarkRecord(latency: UInt64($0) * 1_000_000) },
        invalidRunCount: 0,
        restoreFailureCount: 0
    )
    let driver = BenchmarkDriver()
    let report = await ScreenSwapBenchmarkRunner().run(configuration: configuration, driver: driver, baseline: baseline)
    #expect(report.runs.count == 10)
    #expect(driver.restoreCalls == 12)
    #expect(report.commandToVerifiedComplete?.minMilliseconds == 3)
    #expect(report.commandToVerifiedComplete?.p50Milliseconds == 7)
    #expect(report.commandToVerifiedComplete?.p95Milliseconds == 12)
    #expect(report.regression?.exceeded == true)
    let json = try report.jsonData()
    #expect((try JSONDecoder().decode(ScreenSwapBenchmarkReport.self, from: json)).runs.count == 10)
}
