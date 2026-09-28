import Testing
@testable import ScreenSwapMac

@Test
func runtimeWindowKeyUsesProcessAndQuartzWindowNumber() {
    #expect(RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 1) !=
        RuntimeWindowKey(processIdentifier: 11, quartzWindowNumber: 1))
    #expect(RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 1) !=
        RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 2))
}
