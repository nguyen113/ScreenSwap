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
    #expect(!settings.launchAtLogin)

    let replacement = HotKeyShortcut(keyCode: 12, modifiers: 0x100)
    settings.shortcut = replacement
    settings.launchAtLogin = true
    let reloaded = ScreenSwapSettings(defaults: defaults)
    #expect(reloaded.shortcut == replacement)
    #expect(reloaded.launchAtLogin)
}

@Test
func defaultHotKeyIsDocumentedControlOptionCommandS() {
    #expect(HotKeyShortcut.default.keyCode == 1)
    #expect(HotKeyShortcut.default.modifiers != 0)
}
