import Foundation

/// The live composition root for macOS services. Keeping this construction out
/// of the application lifecycle makes later settings and selection state
/// additions explicit without introducing more SwiftPM targets.
@MainActor
struct AppDependencies {
    let authorization: LiveAccessibilityAuthorizer
    let displayProvider: LiveDisplayProvider
    let windowService: AccessibilityWindowService
    let coordinator: SwapCoordinator

    static func live() -> AppDependencies {
        let authorization = LiveAccessibilityAuthorizer()
        let displayProvider = LiveDisplayProvider()
        let windowService = AccessibilityWindowService(client: LiveAccessibilityClient())
        let coordinator = SwapCoordinator(
            authorization: authorization,
            displays: displayProvider,
            windowProvider: windowService,
            windowApplying: windowService,
            windowRestorer: windowService,
            windowVerifier: windowService,
            performanceRecorder: SwapPerformanceLogger(isEnabled: {
                #if DEBUG
                true
                #else
                DiagnosticsConfiguration.isEnabled(environment: ProcessInfo.processInfo.environment)
                #endif
            }())
        )
        return AppDependencies(
            authorization: authorization,
            displayProvider: displayProvider,
            windowService: windowService,
            coordinator: coordinator
        )
    }
}
