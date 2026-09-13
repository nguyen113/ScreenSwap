import AppKit

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureButton()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }

        button.image = NSImage(
            systemSymbolName: "arrow.left.arrow.right",
            accessibilityDescription: "Swap windows between displays"
        )
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(statusItemClicked)
        button.toolTip = "ScreenSwap"
    }

    @objc
    private func statusItemClicked() {
        // Intentionally not implemented yet.
        // The CGAW backlog introduces swap orchestration in later atomic tasks.
        print("ScreenSwap: swap action is not implemented yet.")
    }
}
