import AppKit
import Carbon
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var activeController: SettingsWindowController?

    static func show(
        settings: ScreenSwapSettings,
        authorization: any AccessibilityAuthorizing,
        shortcutRegistration: ((HotKeyShortcut) -> Bool)?,
        moveShortcutRegistration: ((HotKeyShortcut) -> Bool)?,
        callReturnShortcutRegistration: ((HotKeyShortcut) -> Bool)?
    ) {
        if let activeController {
            AuxiliaryWindowPresenter.present(activeController)
            return
        }
        let accessibility = NSTextField(labelWithString: authorization.isTrusted ? "Accessibility: Granted" : "Accessibility: Required")
        let launch = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: #selector(SettingsActions.toggleLaunch(_:)))
        launch.state = settings.launchAtLogin ? .on : .off
        let grant = NSButton(title: "Grant Accessibility", target: nil, action: #selector(SettingsActions.requestAccessibility(_:)))
        let shortcutStatus = NSTextField(labelWithString: "Swap shortcut")
        let moveShortcutStatus = NSTextField(labelWithString: "Move focused window")
        let callReturnStatus = NSTextField(labelWithString: "Call / Return")
        let actions = SettingsActions(
            settings: settings,
            authorization: authorization,
            accessibilityStatus: accessibility,
            shortcutStatus: shortcutStatus,
            shortcutRegistration: shortcutRegistration,
            moveShortcutStatus: moveShortcutStatus,
            moveShortcutRegistration: moveShortcutRegistration,
            callReturnStatus: callReturnStatus,
            callReturnShortcutRegistration: callReturnShortcutRegistration
        )
        let recorder = ShortcutRecorderField(shortcut: settings.shortcut) { shortcut in
            actions.replaceShortcut(shortcut)
        }
        recorder.toolTip = "Click this field, then press a modified key combination."
        let moveRecorder = ShortcutRecorderField(shortcut: settings.moveShortcut) { shortcut in
            actions.replaceMoveShortcut(shortcut)
        }
        moveRecorder.toolTip = "Click this field, then press a modified key combination."
        let callReturnRecorder = ShortcutRecorderField(shortcut: settings.callReturnShortcut) { shortcut in
            actions.replaceCallReturnShortcut(shortcut)
        }
        callReturnRecorder.toolTip = "Control–Shift–C calls a window; press it again to return. Click to change."
        launch.target = actions
        grant.target = actions

        let shortcutRow = NSStackView(views: [shortcutStatus, recorder])
        shortcutRow.spacing = 12
        shortcutRow.alignment = .centerY
        let moveShortcutRow = NSStackView(views: [moveShortcutStatus, moveRecorder])
        moveShortcutRow.spacing = 12
        moveShortcutRow.alignment = .centerY
        let callReturnRow = NSStackView(views: [callReturnStatus, callReturnRecorder])
        callReturnRow.spacing = 12
        callReturnRow.alignment = .centerY
        let hint = NSTextField(wrappingLabelWithString: "Configure left and middle click in the icon’s right-click menu. Scroll over the icon to change middle click.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [shortcutRow, moveShortcutRow, callReturnRow, hint, launch, accessibility, grant])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 295))
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ScreenSwap Settings"
        window.contentView = view
        let controller = SettingsWindowController(window: window)
        controller.shouldCascadeWindows = true
        window.delegate = controller
        Self.activeController = controller
        AuxiliaryWindowPresenter.present(controller)
    }

    func windowWillClose(_ notification: Notification) {
        if Self.activeController === self { Self.activeController = nil }
    }
}

@MainActor
final class SettingsActions: NSObject {
    let settings: ScreenSwapSettings
    let authorization: any AccessibilityAuthorizing
    let accessibilityStatus: NSTextField
    let shortcutStatus: NSTextField
    let shortcutRegistration: ((HotKeyShortcut) -> Bool)?
    let moveShortcutStatus: NSTextField
    let moveShortcutRegistration: ((HotKeyShortcut) -> Bool)?
    let callReturnStatus: NSTextField
    let callReturnShortcutRegistration: ((HotKeyShortcut) -> Bool)?

    init(settings: ScreenSwapSettings, authorization: any AccessibilityAuthorizing, accessibilityStatus: NSTextField, shortcutStatus: NSTextField, shortcutRegistration: ((HotKeyShortcut) -> Bool)?, moveShortcutStatus: NSTextField, moveShortcutRegistration: ((HotKeyShortcut) -> Bool)?, callReturnStatus: NSTextField, callReturnShortcutRegistration: ((HotKeyShortcut) -> Bool)?) {
        self.settings = settings
        self.authorization = authorization
        self.accessibilityStatus = accessibilityStatus
        self.shortcutStatus = shortcutStatus
        self.shortcutRegistration = shortcutRegistration
        self.moveShortcutStatus = moveShortcutStatus
        self.moveShortcutRegistration = moveShortcutRegistration
        self.callReturnStatus = callReturnStatus
        self.callReturnShortcutRegistration = callReturnShortcutRegistration
    }

    @objc func requestAccessibility(_ sender: Any?) {
        authorization.requestAccess()
        accessibilityStatus.stringValue = "Accessibility: grant access, then reopen Settings"
    }

    @objc func toggleLaunch(_ sender: NSButton) {
        let requested = sender.state == .on
        do {
            if requested { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settings.launchAtLogin = requested
        } catch {
            sender.state = settings.launchAtLogin ? .on : .off
            accessibilityStatus.stringValue = "Launch at login could not be changed."
        }
    }

    func replaceShortcut(_ shortcut: HotKeyShortcut) -> Bool {
        guard shortcut.modifiers != 0 else {
            shortcutStatus.stringValue = "Shortcut needs at least one modifier"
            return false
        }
        guard shortcut != settings.moveShortcut, shortcut != settings.callReturnShortcut else {
            shortcutStatus.stringValue = "Choose a different modified shortcut"
            return false
        }
        let oldShortcut = settings.shortcut
        guard shortcutRegistration?(shortcut) ?? false else {
            _ = shortcutRegistration?(oldShortcut)
            shortcutStatus.stringValue = "Shortcut unavailable — previous shortcut restored"
            return false
        }
        settings.shortcut = shortcut
        shortcutStatus.stringValue = "Swap shortcut"
        return true
    }

    func replaceCallReturnShortcut(_ shortcut: HotKeyShortcut) -> Bool {
        guard shortcut.modifiers != 0, shortcut != settings.shortcut, shortcut != settings.moveShortcut else {
            callReturnStatus.stringValue = "Choose a different modified shortcut"
            return false
        }
        let oldShortcut = settings.callReturnShortcut
        guard callReturnShortcutRegistration?(shortcut) ?? false else {
            _ = callReturnShortcutRegistration?(oldShortcut)
            callReturnStatus.stringValue = "Shortcut unavailable — previous shortcut restored"
            return false
        }
        settings.callReturnShortcut = shortcut
        callReturnStatus.stringValue = "Call / Return"
        return true
    }

    func replaceMoveShortcut(_ shortcut: HotKeyShortcut) -> Bool {
        guard shortcut.modifiers != 0, shortcut != settings.shortcut, shortcut != settings.callReturnShortcut else {
            moveShortcutStatus.stringValue = "Choose a different modified shortcut"
            return false
        }
        let oldShortcut = settings.moveShortcut
        guard moveShortcutRegistration?(shortcut) ?? false else {
            _ = moveShortcutRegistration?(oldShortcut)
            moveShortcutStatus.stringValue = "Shortcut unavailable — previous shortcut restored"
            return false
        }
        settings.moveShortcut = shortcut
        moveShortcutStatus.stringValue = "Move focused window"
        return true
    }
}

@MainActor
private final class ShortcutRecorderField: NSTextField {
    private let onShortcut: (HotKeyShortcut) -> Bool

    init(shortcut: HotKeyShortcut, onShortcut: @escaping (HotKeyShortcut) -> Bool) {
        self.onShortcut = onShortcut
        super.init(frame: NSRect(x: 0, y: 0, width: 155, height: 24))
        stringValue = Self.text(for: shortcut)
        isEditable = false
        isSelectable = false
        alignment = .center
        focusRingType = .default
        bezelStyle = .roundedBezel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        stringValue = "Press shortcut…"
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let shortcut = HotKeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard onShortcut(shortcut) else { return }
        stringValue = Self.text(for: shortcut)
    }

    private static func text(for shortcut: HotKeyShortcut) -> String {
        var result = ""
        if shortcut.modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if shortcut.modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        let keyNames: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M"
        ]
        return result + (keyNames[shortcut.keyCode] ?? "Key \(shortcut.keyCode)")
    }
}
