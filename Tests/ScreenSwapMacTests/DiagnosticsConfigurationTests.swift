import Foundation
import Testing
@testable import ScreenSwapMac

@Test
func releaseDiagnosticsRequireExplicitEnvironmentFlag() {
    #expect(DiagnosticsConfiguration.isEnabled(environment: [:]) == false)
    #expect(DiagnosticsConfiguration.isEnabled(environment: ["SCREENSWAP_DIAGNOSTICS": "0"]) == false)
    #expect(DiagnosticsConfiguration.isEnabled(environment: ["SCREENSWAP_DIAGNOSTICS": "1"]) == true)
    #expect(DiagnosticsConfiguration.isEnabled(environment: [:], localOverride: true) == true)
}


@Test
func diagnosticsURLOverrideWritesWithoutEnvironmentFlag() throws {
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: destination) }
    DiagnosticsConfiguration.append("capture", environment: [:], localOverride: true, destination: destination)
    DiagnosticsConfiguration.append("apply", environment: [:], localOverride: true, destination: destination)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "capture\napply\n")
}
