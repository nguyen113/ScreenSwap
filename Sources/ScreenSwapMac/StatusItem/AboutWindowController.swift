import AppKit

@MainActor
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()
    private init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let text = NSTextField(wrappingLabelWithString: "ScreenSwap\nVersion \(version)")
        text.alignment = .center
        let github = NSButton(title: "Open GitHub", target: nil, action: #selector(openGitHub))
        let stack = NSStackView(views: [text, github])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 130))
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About ScreenSwap"; window.contentView = view
        super.init(window: window)
        github.target = self
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        AuxiliaryWindowPresenter.present(self)
    }

    @objc private func openGitHub() { NSWorkspace.shared.open(URL(string: "https://github.com/nguyen113/ScreenSwap-Gpt")!) }
}
