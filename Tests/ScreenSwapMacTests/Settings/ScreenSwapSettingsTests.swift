import Foundation
import Testing
@testable import ScreenSwapMac

@Test
@MainActor
func settingsPersistShortcutAndLaunchPreference() {
    let suiteName = "ScreenSwapTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = ScreenSwapSettings(defaults: defaults)
    #expect(settings.shortcut == .default)
    #expect(settings.moveShortcut == .defaultMove)
    #expect(!settings.launchAtLogin)
    #expect(settings.defaultClickMode == .swap)

    let replacement = HotKeyShortcut(keyCode: 12, modifiers: 0x100)
    settings.shortcut = replacement
    let moveReplacement = HotKeyShortcut(keyCode: 46, modifiers: 0x1800)
    settings.moveShortcut = moveReplacement
    settings.launchAtLogin = true
    settings.defaultClickMode = .move
    let reloaded = ScreenSwapSettings(defaults: defaults)
    #expect(reloaded.shortcut == replacement)
    #expect(reloaded.moveShortcut == moveReplacement)
    #expect(reloaded.launchAtLogin)
    #expect(reloaded.defaultClickMode == .move)
}

@Test
@MainActor
func invalidClickModeFallsBackToSwap() {
    let suiteName = "ScreenSwapTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("invalid", forKey: "ScreenSwap.defaultClickMode")
    #expect(ScreenSwapSettings(defaults: defaults).defaultClickMode == .swap)
}

@Test
func defaultHotKeyIsControlShiftS() {
    #expect(HotKeyShortcut.default.keyCode == 1)
    #expect(HotKeyShortcut.default.modifiers == 0x1200)
    #expect(HotKeyShortcut.defaultMove.keyCode == 1)
    #expect(HotKeyShortcut.defaultMove.modifiers == 0x1A00)
}
