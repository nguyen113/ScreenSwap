import AppKit
import Foundation

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var dependencies: AppDependencies?
    private var hotKeyService: GlobalHotKeyService?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let dependencies = AppDependencies.live()
        self.dependencies = dependencies
        hotKeyService = GlobalHotKeyService()
        statusBarController = StatusBarController(
            coordinator: dependencies.coordinator,
            authorization: dependencies.authorization,
            settings: dependencies.settings,
            inventoryProvider: dependencies.menuInventory,
            selection: dependencies.selectionStore,
            displaySelection: dependencies.displayPairSelectionStore,
            shortcutRegistration: { [weak self] shortcut in
                self?.registerGlobalShortcut(shortcut) ?? false
            },
            moveShortcutRegistration: { [weak self] shortcut in
                self?.registerMoveShortcut(shortcut) ?? false
            }
        )
        _ = registerGlobalShortcut(dependencies.settings.shortcut)
        _ = registerMoveShortcut(dependencies.settings.moveShortcut)
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
        let primaryDisplayID = dependencies.displayProvider.primaryDisplayID()
        dependencies.displayPairSelectionStore.reconcile(
            activeDisplays: displays,
            primaryDisplayID: primaryDisplayID,
            candidateCounts: dependencies.windowService.candidateCounts(activeDisplays: displays)
        )
        let selectedDisplays = dependencies.displayPairSelectionStore.frozenPair().compactMap { id in
            displays.first { $0.id == id }
        }
        _ = dependencies.windowService.captureWindows(
            activeDisplays: displays,
            selectedDisplays: selectedDisplays
        )
    }

    private func registerGlobalShortcut(_ shortcut: HotKeyShortcut) -> Bool {
        hotKeyService?.register(shortcut) { [weak self] in
            self?.statusBarController?.triggerSwap()
        } ?? false
    }

    private func registerMoveShortcut(_ shortcut: HotKeyShortcut) -> Bool {
        hotKeyService?.registerMove(shortcut) { [weak self] in
            self?.statusBarController?.triggerMoveFocusedWindow()
        } ?? false
    }
}
