import Darwin
import Foundation

/// A monotonic, high-resolution source used for swap instrumentation. Values
/// are only compared within a process and are never wall-clock timestamps.
@MainActor
public protocol MonotonicTimeSource: AnyObject {
    func nowNanoseconds() -> UInt64
}

@MainActor
public final class MachContinuousTimeSource: MonotonicTimeSource {
    private let numer: UInt64
    private let denom: UInt64

    public init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        numer = UInt64(timebase.numer)
        denom = UInt64(timebase.denom)
    }

    public func nowNanoseconds() -> UInt64 {
        let ticks = mach_continuous_time()
        // Divide first when possible so a long-running process cannot overflow.
        let quotient = ticks / denom
        let remainder = ticks % denom
        return quotient &* numer &+ (remainder &* numer) / denom
    }
}

public struct SwapPerformanceRecord: Codable, Equatable, Sendable {
    public let operationID: String
    public let outcome: String
    public let commandReceivedNanoseconds: UInt64
    public let windowsDiscoveredNanoseconds: UInt64
    public let targetFramesCalculatedNanoseconds: UInt64
    public let firstWindowMoveStartedNanoseconds: UInt64
    public let lastWindowMoveCommandCompletedNanoseconds: UInt64
    public let finalStateVerifiedNanoseconds: UInt64
    public let windowsTotal: Int
    public let windowsEligible: Int
    public let windowsSkipped: Int
    public let skipReasons: [String: Int]
    public let planned: Int
    public let attempted: Int
    public let succeeded: Int
    public let failed: Int
    public let verificationSucceeded: Bool
    public let verificationTimedOut: Bool

    public init(
        operationID: String,
        outcome: String = "unknown",
        commandReceivedNanoseconds: UInt64,
        windowsDiscoveredNanoseconds: UInt64,
        targetFramesCalculatedNanoseconds: UInt64,
        firstWindowMoveStartedNanoseconds: UInt64,
        lastWindowMoveCommandCompletedNanoseconds: UInt64,
        finalStateVerifiedNanoseconds: UInt64,
        windowsTotal: Int,
        windowsEligible: Int,
        windowsSkipped: Int,
        skipReasons: [String: Int] = [:],
        planned: Int? = nil,
        attempted: Int,
        succeeded: Int,
        failed: Int,
        verificationSucceeded: Bool,
        verificationTimedOut: Bool
    ) {
        self.operationID = operationID
        self.outcome = outcome
        self.commandReceivedNanoseconds = commandReceivedNanoseconds
        self.windowsDiscoveredNanoseconds = windowsDiscoveredNanoseconds
        self.targetFramesCalculatedNanoseconds = targetFramesCalculatedNanoseconds
        self.firstWindowMoveStartedNanoseconds = firstWindowMoveStartedNanoseconds
        self.lastWindowMoveCommandCompletedNanoseconds = lastWindowMoveCommandCompletedNanoseconds
        self.finalStateVerifiedNanoseconds = finalStateVerifiedNanoseconds
        self.windowsTotal = windowsTotal
        self.windowsEligible = windowsEligible
        self.windowsSkipped = windowsSkipped
        self.skipReasons = skipReasons
        self.planned = planned ?? attempted
        self.attempted = attempted
        self.succeeded = succeeded
        self.failed = failed
        self.verificationSucceeded = verificationSucceeded
        self.verificationTimedOut = verificationTimedOut
    }

    public var discoveryNanoseconds: UInt64 { windowsDiscoveredNanoseconds - commandReceivedNanoseconds }
    public var calculationNanoseconds: UInt64 { targetFramesCalculatedNanoseconds - windowsDiscoveredNanoseconds }
    public var firstMoveNanoseconds: UInt64 { firstWindowMoveStartedNanoseconds - commandReceivedNanoseconds }
    public var dispatchNanoseconds: UInt64 { firstWindowMoveStartedNanoseconds - targetFramesCalculatedNanoseconds }
    public var moveExecutionNanoseconds: UInt64 { lastWindowMoveCommandCompletedNanoseconds - firstWindowMoveStartedNanoseconds }
    public var verificationNanoseconds: UInt64 { finalStateVerifiedNanoseconds - lastWindowMoveCommandCompletedNanoseconds }
    public var coreLatencyNanoseconds: UInt64 { lastWindowMoveCommandCompletedNanoseconds - commandReceivedNanoseconds }
    public var verifiedLatencyNanoseconds: UInt64 { finalStateVerifiedNanoseconds - commandReceivedNanoseconds }

    public var logLine: String {
        "[ScreenSwapPerf] operation_id=\(operationID) outcome=\(outcome) windows_total=\(windowsTotal) windows_eligible=\(windowsEligible) windows_skipped=\(windowsSkipped) skip_reasons=\(skipReasons.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")) planned=\(planned) attempted=\(attempted) succeeded=\(succeeded) failed=\(failed) discovery_ms=\(milliseconds(discoveryNanoseconds)) calculation_ms=\(milliseconds(calculationNanoseconds)) first_move_ms=\(milliseconds(firstMoveNanoseconds)) move_execution_ms=\(milliseconds(moveExecutionNanoseconds)) verification_ms=\(milliseconds(verificationNanoseconds)) core_latency_ms=\(milliseconds(coreLatencyNanoseconds)) verified_latency_ms=\(milliseconds(verifiedLatencyNanoseconds)) verified=\(verificationSucceeded)"
    }

    private func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }
}

@MainActor
public protocol SwapPerformanceRecording: AnyObject {
    func record(_ measurement: SwapPerformanceRecord)
}

/// Keeps performance logging opt-in. The application enables it for DEBUG;
/// benchmark callers can explicitly enable it in any build configuration.
@MainActor
public final class SwapPerformanceLogger: SwapPerformanceRecording {
    public var isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    public func record(_ measurement: SwapPerformanceRecord) {
        guard isEnabled else { return }
        print(measurement.logLine)
    }
}

public struct MeasuredSwapResult: Sendable {
    public let outcome: SwapOutcome
    public let performance: SwapPerformanceRecord

    public init(outcome: SwapOutcome, performance: SwapPerformanceRecord) {
        self.outcome = outcome
        self.performance = performance
    }
}
