import Foundation

public struct ScreenSwapBenchmarkConfiguration: Codable, Equatable, Sendable {
    public let scenario: String
    public let displayCount: Int
    public let declaredWindowCount: Int?
    public let stageManager: String
    public let warmupRuns: Int
    public let measuredRuns: Int

    public init(
        scenario: String,
        displayCount: Int = 2,
        declaredWindowCount: Int? = nil,
        stageManager: String,
        warmupRuns: Int = 10,
        measuredRuns: Int = 100
    ) {
        self.scenario = scenario
        self.displayCount = displayCount
        self.declaredWindowCount = declaredWindowCount
        self.stageManager = stageManager
        self.warmupRuns = warmupRuns
        self.measuredRuns = measuredRuns
    }
}

@MainActor
public protocol SwapBenchmarkDriving: AnyObject {
    /// Executes the operation being measured. The implementation must capture
    /// T0 before it hands work to an async task.
    func performMeasuredSwap() async -> MeasuredSwapResult
    /// Restores the scenario before the next measured operation. Its timing is
    /// intentionally not included in benchmark statistics.
    func restoreScenario() async -> MeasuredSwapResult
}

@MainActor
public final class CoordinatorBenchmarkDriver: SwapBenchmarkDriving {
    private let coordinator: SwapCoordinator

    public init(coordinator: SwapCoordinator) {
        self.coordinator = coordinator
    }

    public func performMeasuredSwap() async -> MeasuredSwapResult {
        let t0 = coordinator.commandReceivedNanoseconds()
        return await coordinator.swapMeasured(commandReceivedNanoseconds: t0)
    }

    public func restoreScenario() async -> MeasuredSwapResult {
        let t0 = coordinator.commandReceivedNanoseconds()
        return await coordinator.swapMeasured(commandReceivedNanoseconds: t0)
    }
}

public struct PerformanceDistribution: Codable, Equatable, Sendable {
    public let minMilliseconds: Double
    public let meanMilliseconds: Double
    public let p50Milliseconds: Double
    public let p90Milliseconds: Double
    public let p95Milliseconds: Double
    public let p99Milliseconds: Double
    public let maxMilliseconds: Double
    public let standardDeviationMilliseconds: Double

    public init(samplesNanoseconds: [UInt64]) {
        let values = samplesNanoseconds.map { Double($0) / 1_000_000 }.sorted()
        precondition(!values.isEmpty, "A distribution requires at least one valid sample")
        minMilliseconds = values[0]
        maxMilliseconds = values[values.count - 1]
        let mean = values.reduce(0, +) / Double(values.count)
        meanMilliseconds = mean
        p50Milliseconds = Self.percentile(0.50, values: values)
        p90Milliseconds = Self.percentile(0.90, values: values)
        p95Milliseconds = Self.percentile(0.95, values: values)
        p99Milliseconds = Self.percentile(0.99, values: values)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        standardDeviationMilliseconds = sqrt(variance)
    }

    private static func percentile(_ percentile: Double, values: [Double]) -> Double {
        // Nearest-rank percentile: p95 of 100 runs is the 95th sorted sample.
        let index = max(0, Int(ceil(percentile * Double(values.count))) - 1)
        return values[index]
    }
}

public struct PerformanceRegression: Codable, Equatable, Sendable {
    public let baselineP95Milliseconds: Double
    public let currentP95Milliseconds: Double
    public let percentage: Double
    public let thresholdPercentage: Double
    public let exceeded: Bool
}

public struct ScreenSwapBenchmarkReport: Codable, Sendable {
    public let configuration: ScreenSwapBenchmarkConfiguration
    public let runs: [SwapPerformanceRecord]
    public let invalidRunCount: Int
    public let restoreFailureCount: Int
    public let commandToFirstMove: PerformanceDistribution?
    public let commandToVerifiedComplete: PerformanceDistribution?
    public let commandToCoreComplete: PerformanceDistribution?
    public let target150MillisecondsPassed: Bool
    public let hard200MillisecondsPassed: Bool
    public let regression: PerformanceRegression?

    public init(
        configuration: ScreenSwapBenchmarkConfiguration,
        runs: [SwapPerformanceRecord],
        invalidRunCount: Int,
        restoreFailureCount: Int,
        baseline: ScreenSwapBenchmarkReport? = nil,
        regressionThresholdPercentage: Double = 15
    ) {
        self.configuration = configuration
        self.runs = runs
        self.invalidRunCount = invalidRunCount
        self.restoreFailureCount = restoreFailureCount
        let valid = runs.filter(\.verificationSucceeded)
        commandToFirstMove = valid.isEmpty ? nil : PerformanceDistribution(samplesNanoseconds: valid.map(\.firstMoveNanoseconds))
        commandToVerifiedComplete = valid.isEmpty ? nil : PerformanceDistribution(samplesNanoseconds: valid.map(\.verifiedLatencyNanoseconds))
        commandToCoreComplete = valid.isEmpty ? nil : PerformanceDistribution(samplesNanoseconds: valid.map(\.coreLatencyNanoseconds))
        target150MillisecondsPassed = valid.count == runs.count && (commandToVerifiedComplete?.p95Milliseconds ?? .infinity) <= 150
        hard200MillisecondsPassed = valid.count == runs.count && (commandToVerifiedComplete?.p95Milliseconds ?? .infinity) <= 200
        if let baselineP95 = baseline?.commandToVerifiedComplete?.p95Milliseconds,
           let currentP95 = commandToVerifiedComplete?.p95Milliseconds {
            let percentage = baselineP95 == 0 ? 0 : ((currentP95 - baselineP95) / baselineP95) * 100
            regression = PerformanceRegression(
                baselineP95Milliseconds: baselineP95,
                currentP95Milliseconds: currentP95,
                percentage: percentage,
                thresholdPercentage: regressionThresholdPercentage,
                exceeded: percentage > regressionThresholdPercentage
            )
        } else {
            regression = nil
        }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public var consoleSummary: String {
        guard let first = commandToFirstMove, let total = commandToVerifiedComplete else {
            return "ScreenSwap Performance Benchmark\nResult: INVALID — \(invalidRunCount) run(s) did not reach a verified final state."
        }
        let windowText = configuration.declaredWindowCount.map(String.init) ?? "captured per run"
        var lines = [
            "ScreenSwap Performance Benchmark",
            "Configuration:",
            "Scenario: \(configuration.scenario)",
            "Displays: \(configuration.displayCount)",
            "Windows: \(windowText)",
            "Runs: \(runs.count)",
            "Stage Manager: \(configuration.stageManager)",
            "Command → First Move",
            String(format: "p50: %.2f ms", first.p50Milliseconds),
            String(format: "p95: %.2f ms", first.p95Milliseconds),
            "Command → Swap Complete (verified)",
            String(format: "p50: %.2f ms", total.p50Milliseconds),
            String(format: "p95: %.2f ms", total.p95Milliseconds),
            String(format: "p99: %.2f ms", total.p99Milliseconds),
            String(format: "max: %.2f ms", total.maxMilliseconds),
            "Result:",
            "Target <=150 ms: \(target150MillisecondsPassed ? "PASS" : "FAIL")",
            "Hard limit <=200 ms: \(hard200MillisecondsPassed ? "PASS" : "FAIL")"
        ]
        if invalidRunCount > 0 { lines.append("Invalid (unverified) runs: \(invalidRunCount)") }
        if restoreFailureCount > 0 { lines.append("Restore failures: \(restoreFailureCount)") }
        if let regression {
            lines.append(String(format: "p95 regression: %.2f%% (%@)", regression.percentage, regression.exceeded ? "WARNING" : "within threshold"))
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
public final class ScreenSwapBenchmarkRunner {
    public init() {}

    public func run(
        configuration: ScreenSwapBenchmarkConfiguration,
        driver: any SwapBenchmarkDriving,
        baseline: ScreenSwapBenchmarkReport? = nil,
        regressionThresholdPercentage: Double = 15
    ) async -> ScreenSwapBenchmarkReport {
        var measured: [SwapPerformanceRecord] = []
        var invalid = 0
        var restoreFailures = 0
        let allRuns = configuration.warmupRuns + configuration.measuredRuns
        for index in 0..<allRuns {
            let result = await driver.performMeasuredSwap()
            if index >= configuration.warmupRuns {
                measured.append(result.performance)
                if !result.performance.verificationSucceeded { invalid += 1 }
            }
            let restore = await driver.restoreScenario()
            if !restore.performance.verificationSucceeded { restoreFailures += 1 }
        }
        return ScreenSwapBenchmarkReport(
            configuration: configuration,
            runs: measured,
            invalidRunCount: invalid,
            restoreFailureCount: restoreFailures,
            baseline: baseline,
            regressionThresholdPercentage: regressionThresholdPercentage
        )
    }
}
