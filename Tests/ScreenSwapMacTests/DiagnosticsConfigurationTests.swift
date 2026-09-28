import Testing
@testable import ScreenSwapMac

@Test
func releaseDiagnosticsRequireExplicitEnvironmentFlag() {
    #expect(DiagnosticsConfiguration.isEnabled(environment: [:]) == false)
    #expect(DiagnosticsConfiguration.isEnabled(environment: ["SCREENSWAP_DIAGNOSTICS": "0"]) == false)
    #expect(DiagnosticsConfiguration.isEnabled(environment: ["SCREENSWAP_DIAGNOSTICS": "1"]) == true)
    #expect(DiagnosticsConfiguration.isEnabled(environment: [:], localOverride: true) == true)
}
