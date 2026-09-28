import AppKit

/// Presentation policy for the small app-owned windows opened from an
/// accessory status item. These windows must not inherit a hidden ordering
/// from the menu-bar app or an inactive Space.
@MainActor
enum AuxiliaryWindowPresenter {
    static func present(_ controller: NSWindowController) {
        guard let window = controller.window else { return }
        window.collectionBehavior.insert(.moveToActiveSpace)
        if let visibleFrame = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(centeredOrigin(windowSize: window.frame.size, in: visibleFrame))
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    static func centeredOrigin(windowSize: CGSize, in visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.midY - windowSize.height / 2
        )
    }
}
