import AppKit

@MainActor
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()
    static let githubURL = URL(string: "https://github.com/nguyen113/ScreenSwap-Gpt")!
    static let supportURL = URL(string: "https://ko-fi.com/C3N027TX55")!

    private init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let text = NSTextField(wrappingLabelWithString: "ScreenSwap\nVersion \(version)")
        text.alignment = .center
        let github = NSButton(title: "Open GitHub", target: nil, action: #selector(openGitHub))
        let support = NSButton(title: "Support ScreenSwap on Ko-fi", target: nil, action: #selector(openSupport))
        let icon = NSImageView(image: StatusIconImages.appIcon ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 64), icon.heightAnchor.constraint(equalToConstant: 64)])
        let stack = NSStackView(views: [icon, text, github, support])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 246))
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About ScreenSwap"; window.contentView = view
        super.init(window: window)
        github.target = self
        support.target = self
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        AuxiliaryWindowPresenter.present(self)
    }

    @objc private func openGitHub() { NSWorkspace.shared.open(Self.githubURL) }
    @objc private func openSupport() { NSWorkspace.shared.open(Self.supportURL) }
}
