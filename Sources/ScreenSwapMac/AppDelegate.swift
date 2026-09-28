import AppKit
import Foundation

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var authorization: LiveAccessibilityAuthorizer?
    private var displayProvider: LiveDisplayProvider?
    private var windowService: AccessibilityWindowService?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let authorization = LiveAccessibilityAuthorizer()
        let displayProvider = LiveDisplayProvider()
        let accessibilityClient = LiveAccessibilityClient()
        let windowService = AccessibilityWindowService(client: accessibilityClient)
        self.authorization = authorization
        self.displayProvider = displayProvider
        self.windowService = windowService
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
        statusBarController = StatusBarController(
            coordinator: coordinator,
            authorization: authorization
        )
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: ScreenSwapCommandURL.isSwapCommand) {
            statusBarController?.triggerSwap()
        }
        if urls.contains(where: ScreenSwapCommandURL.isDiagnosticsCommand) {
            captureDiagnostics()
        }
    }

    private func captureDiagnostics() {
        windowService?.enableDiagnostics()
        guard authorization?.isTrusted == true,
              let displayProvider,
              let windowService,
              let displays = try? displayProvider.currentDisplays() else {
            return
        }
        _ = windowService.captureWindows(displays: displays)
    }
}
