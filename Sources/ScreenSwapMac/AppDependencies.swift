import Foundation

/// The live composition root for macOS services. Keeping this construction out
/// of the application lifecycle makes later settings and selection state
/// additions explicit without introducing more SwiftPM targets.
@MainActor
struct AppDependencies {
    let authorization: LiveAccessibilityAuthorizer
    let displayProvider: LiveDisplayProvider
    let windowService: AccessibilityWindowService
    let selectionStore: WindowSelectionStore
    let displayPairSelectionStore: DisplayPairSelectionStore
    let settings: ScreenSwapSettings
    let menuInventory: LiveStatusItemInventoryProvider
    let coordinator: SwapCoordinator

    static func live() -> AppDependencies {
        let authorization = LiveAccessibilityAuthorizer()
        let displayProvider = LiveDisplayProvider()
        let windowService = AccessibilityWindowService(
            client: LiveAccessibilityClient(),
            inventoryClient: LiveAccessibilityClient()
        )
        let selectionStore = WindowSelectionStore()
        let displayPairSelectionStore = DisplayPairSelectionStore()
        let settings = ScreenSwapSettings()
        let menuInventory = LiveStatusItemInventoryProvider(
            authorization: authorization,
            displays: displayProvider,
            namedDisplays: displayProvider,
            windows: windowService,
            displaySelection: displayPairSelectionStore
        )
        let coordinator = SwapCoordinator(
            authorization: authorization,
            displays: displayProvider,
            windowProvider: windowService,
            windowApplying: windowService,
            windowRestorer: windowService,
            windowVerifier: windowService,
            selection: selectionStore,
            displaySelection: displayPairSelectionStore,
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
            selectionStore: selectionStore,
            displayPairSelectionStore: displayPairSelectionStore,
            settings: settings,
            menuInventory: menuInventory,
            coordinator: coordinator
        )
    }
}
