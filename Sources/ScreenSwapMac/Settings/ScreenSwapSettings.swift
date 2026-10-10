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
    public static let defaultCallReturn = HotKeyShortcut(
        keyCode: 8,
        modifiers: UInt32(controlKey | shiftKey)
    ) // ⌃⇧C
}

@MainActor
public final class ScreenSwapSettings {
    private let defaults: UserDefaults
    private let shortcutKey = "ScreenSwap.shortcut"
    private let moveShortcutKey = "ScreenSwap.moveShortcut"
    private let launchKey = "ScreenSwap.launchAtLogin"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    /// nil follows macOS. Keep a disconnected preference so reconnecting the
    /// same display restores the user's choice.
    public var preferredPrimaryDisplayID: UInt32? {
        get {
            guard let number = defaults.object(forKey: "ScreenSwap.primaryDisplayID") as? NSNumber,
                  let id = UInt32(exactly: number.int64Value), id != 0 else { return nil }
            return id
        }
        set {
            if let newValue, newValue != 0 {
                defaults.set(NSNumber(value: newValue), forKey: "ScreenSwap.primaryDisplayID")
            } else {
                defaults.removeObject(forKey: "ScreenSwap.primaryDisplayID")
            }
        }
    }
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
    public var callReturnShortcut: HotKeyShortcut {
        get { (try? defaults.data(forKey: "ScreenSwap.callReturnShortcut").flatMap { try JSONDecoder().decode(HotKeyShortcut.self, from: $0) }) ?? .defaultCallReturn }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "ScreenSwap.callReturnShortcut") }
    }
    /// Compatibility with the existing two-mode setting; new UI uses primaryMode.
    public var defaultClickMode: WindowActionMode {
        get { primaryMode == .move ? .move : .swap }
        set { primaryMode = newValue == .move ? .move : .swap }
    }
    public var primaryMode: InteractionMode {
        get {
            defaults.string(forKey: "ScreenSwap.primaryMode").flatMap(InteractionMode.init(rawValue:))
                ?? defaults.string(forKey: "ScreenSwap.defaultClickMode").flatMap(InteractionMode.init(rawValue:))
                ?? .swap
        }
        set {
            let old = primaryMode
            if newValue == secondaryMode { defaults.set(old.rawValue, forKey: "ScreenSwap.secondaryMode") }
            defaults.set(newValue.rawValue, forKey: "ScreenSwap.primaryMode")
        }
    }
    public var secondaryMode: InteractionMode {
        get {
            let saved = defaults.string(forKey: "ScreenSwap.secondaryMode").flatMap(InteractionMode.init(rawValue:))
                ?? (primaryMode == .move ? .swap : .move)
            return saved == primaryMode ? (InteractionMode.allCases.first { $0 != primaryMode }!) : saved
        }
        set {
            let old = secondaryMode
            if newValue == primaryMode { defaults.set(old.rawValue, forKey: "ScreenSwap.primaryMode") }
            defaults.set(newValue.rawValue, forKey: "ScreenSwap.secondaryMode")
        }
    }
    public func cycleSecondaryMode(forward: Bool) {
        let modes = InteractionMode.allCases.filter { $0 != primaryMode }
        let index = modes.firstIndex(of: secondaryMode) ?? 0
        secondaryMode = modes[(index + (forward ? 1 : modes.count - 1)) % modes.count]
    }
}
