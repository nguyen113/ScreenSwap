import AppKit
import Foundation
import ScreenSwapMac

@main
struct ScreenSwapBenchmarkCommand {
    @MainActor
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            guard options.confirmLiveWindows else {
                throw UsageError("Refusing to move live windows. Re-run with --confirm-live-windows after arranging the requested scenario.")
            }
            _ = NSApplication.shared
            let authorization = LiveAccessibilityAuthorizer()
            guard authorization.isTrusted else {
                throw UsageError("Accessibility permission is required. Grant it to ScreenSwapBenchmark, then rerun.")
            }
            let service = AccessibilityWindowService(client: LiveAccessibilityClient())
            let coordinator = SwapCoordinator(
                authorization: authorization,
                displays: LiveDisplayProvider(),
                windowProvider: service,
                windowApplying: service,
                windowVerifier: service,
                performanceRecorder: SwapPerformanceLogger(isEnabled: true)
            )
            let baseline = try options.baseline.map { try loadReport(at: $0) }
            let configuration = ScreenSwapBenchmarkConfiguration(
                scenario: options.scenario,
                displayCount: 2,
                declaredWindowCount: options.windowCount,
                stageManager: options.stageManager,
                warmupRuns: options.warmupRuns,
                measuredRuns: options.measuredRuns
            )
            let report = await ScreenSwapBenchmarkRunner().run(
                configuration: configuration,
                driver: CoordinatorBenchmarkDriver(coordinator: coordinator),
                baseline: baseline,
                regressionThresholdPercentage: options.regressionThreshold
            )
            try report.jsonData().write(to: options.output, options: .atomic)
            print(report.consoleSummary)
            print("JSON: \(options.output.path)")
            if options.failOnRegression && report.regression?.exceeded == true { exit(3) }
            if options.failOnTarget && !report.hard200MillisecondsPassed { exit(4) }
        } catch let error as UsageError {
            fputs("ScreenSwapBenchmark: \(error.message)\n\n\(Options.usage)\n", stderr)
            exit(2)
        } catch {
            fputs("ScreenSwapBenchmark failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func loadReport(at url: URL) throws -> ScreenSwapBenchmarkReport {
        try JSONDecoder().decode(ScreenSwapBenchmarkReport.self, from: Data(contentsOf: url))
    }
}

private struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private struct Options {
    let scenario: String
    let windowCount: Int?
    let stageManager: String
    let warmupRuns: Int
    let measuredRuns: Int
    let output: URL
    let baseline: URL?
    let regressionThreshold: Double
    let failOnRegression: Bool
    let failOnTarget: Bool
    let confirmLiveWindows: Bool

    static let usage = """
    Usage: swift run ScreenSwapBenchmark --scenario P01 --stage-manager OFF --confirm-live-windows [options]

    The operator must arrange the named live scenario before running. Each measured
    swap is followed by one unmeasured swap to restore the starting arrangement.
    Options: --windows N --warmup N (default 10) --runs N (default 100)
             --output performance-results.json --baseline baseline.json
             --regression-threshold 15 --fail-on-regression --fail-on-target
    """

    init(arguments: [String]) throws {
        var values = arguments
        func value(_ flag: String) throws -> String {
            guard let index = values.firstIndex(of: flag), index + 1 < values.count else {
                throw UsageError("Missing value for \(flag)")
            }
            let result = values[index + 1]
            values.removeSubrange(index...(index + 1))
            return result
        }
        func bool(_ flag: String) -> Bool {
            guard let index = values.firstIndex(of: flag) else { return false }
            values.remove(at: index)
            return true
        }
        if bool("--help") { throw UsageError("") }
        scenario = try value("--scenario")
        guard ["P01", "P02", "P03", "P04", "P05", "P06", "P07", "P08", "P09", "P10"].contains(scenario) else {
            throw UsageError("--scenario must be P01 through P10")
        }
        stageManager = try value("--stage-manager").uppercased()
        guard ["ON", "OFF", "UNKNOWN"].contains(stageManager) else {
            throw UsageError("--stage-manager must be ON, OFF, or UNKNOWN")
        }
        let windowString: String? = values.contains("--windows") ? try value("--windows") : nil
        windowCount = try windowString.map { try Self.positiveInteger($0, flag: "--windows") }
        warmupRuns = try values.contains("--warmup") ? Self.positiveInteger(try value("--warmup"), flag: "--warmup") : 10
        measuredRuns = try values.contains("--runs") ? Self.positiveInteger(try value("--runs"), flag: "--runs") : 100
        output = URL(fileURLWithPath: values.contains("--output") ? try value("--output") : "performance-results.json")
        baseline = values.contains("--baseline") ? URL(fileURLWithPath: try value("--baseline")) : nil
        regressionThreshold = try values.contains("--regression-threshold") ? Self.positiveDouble(try value("--regression-threshold"), flag: "--regression-threshold") : 15
        failOnRegression = bool("--fail-on-regression")
        failOnTarget = bool("--fail-on-target")
        confirmLiveWindows = bool("--confirm-live-windows")
        guard values.isEmpty else { throw UsageError("Unknown option: \(values[0])") }
    }

    private static func positiveInteger(_ value: String, flag: String) throws -> Int {
        guard let integer = Int(value), integer > 0 else { throw UsageError("\(flag) must be a positive integer") }
        return integer
    }

    private static func positiveDouble(_ value: String, flag: String) throws -> Double {
        guard let number = Double(value), number > 0 else { throw UsageError("\(flag) must be a positive number") }
        return number
    }
}
