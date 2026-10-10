import Carbon
import Foundation

public enum WindowActionMode: String, CaseIterable, Sendable {
    case swap
    case move

    public var secondary: Self { self == .swap ? .move : .swap }
    public var title: String { rawValue.uppercased() }
}

public struct HotKeyShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public static let `default` = HotKeyShortcut(
        keyCode: 1,
        modifiers: UInt32(controlKey | shiftKey)
    ) // ⌃⇧S
    public static let defaultMove = HotKeyShortcut(
        keyCode: 1,
        modifiers: UInt32(controlKey | optionKey | shiftKey)
    ) // ⌃⌥⇧S
}

@MainActor
public final class ScreenSwapSettings {
    private let defaults: UserDefaults
    private let shortcutKey = "ScreenSwap.shortcut"
    private let moveShortcutKey = "ScreenSwap.moveShortcut"
    private let launchKey = "ScreenSwap.launchAtLogin"
    private let clickModeKey = "ScreenSwap.defaultClickMode"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var shortcut: HotKeyShortcut {
        get { (try? defaults.data(forKey: shortcutKey).flatMap { try JSONDecoder().decode(HotKeyShortcut.self, from: $0) }) ?? .default }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: shortcutKey) }
    }
    public var moveShortcut: HotKeyShortcut {
        get { (try? defaults.data(forKey: moveShortcutKey).flatMap { try JSONDecoder().decode(HotKeyShortcut.self, from: $0) }) ?? .defaultMove }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: moveShortcutKey) }
    }
    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: launchKey) }
        set { defaults.set(newValue, forKey: launchKey) }
    }
    public var defaultClickMode: WindowActionMode {
        get { defaults.string(forKey: clickModeKey).flatMap(WindowActionMode.init(rawValue:)) ?? .swap }
        set { defaults.set(newValue.rawValue, forKey: clickModeKey) }
    }
}
