import Foundation

/// Enables the non-sensitive per-invocation diagnostics logger in any build.
/// This is intentionally opt-in for release builds so normal status-item use
/// does not emit operational telemetry to standard output.
public enum DiagnosticsConfiguration {
    /// Opt-in local diagnostic output. Entries contain only aggregate counts,
    /// opaque ordinals, display IDs, and geometry—never titles or document
    /// content—and are retained only in the system temporary directory.
    public static let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("screenswap-diagnostics.log")

    public static func isEnabled(
        environment: [String: String],
        localOverride: Bool = false
    ) -> Bool {
        localOverride || environment["SCREENSWAP_DIAGNOSTICS"] == "1"
    }

    public static func append(
        _ message: String,
        environment: [String: String],
        localOverride: Bool = false,
        destination: URL = logURL
    ) {
        guard isEnabled(environment: environment, localOverride: localOverride),
              let data = (message + "\n").data(using: .utf8) else {
            return
        }
        if FileManager.default.fileExists(atPath: destination.path),
           let handle = try? FileHandle(forWritingTo: destination) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: destination, options: .atomic)
        }
    }
}
