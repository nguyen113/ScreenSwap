import AppKit
import Foundation

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var dependencies: AppDependencies?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let dependencies = AppDependencies.live()
        self.dependencies = dependencies
        statusBarController = StatusBarController(
            coordinator: dependencies.coordinator,
            authorization: dependencies.authorization
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
        guard let dependencies else { return }

        // Enable the process-local diagnostics route even before Accessibility
        // is granted. A later authorized capture in this process must retain
        // the user's explicit diagnostics request.
        dependencies.windowService.enableDiagnostics()

        guard dependencies.authorization.isTrusted,
          let displays = try? dependencies.displayProvider.currentDisplays() else {
            return
        }
        _ = dependencies.windowService.captureWindows(displays: displays)
    }
}
