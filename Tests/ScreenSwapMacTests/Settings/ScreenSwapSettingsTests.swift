import AppKit
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

@Test @MainActor
func clickModesAndCallReturnShortcutPersistAndScrollPreservesPrimary() {
    let suiteName = "ScreenSwapTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = ScreenSwapSettings(defaults: defaults)
    #expect(settings.primaryMode == .swap && settings.secondaryMode == .move)
    #expect(settings.callReturnShortcut == .defaultCallReturn)
    #expect(HotKeyShortcut.defaultCallReturn.keyCode == 8)
    #expect(HotKeyShortcut.defaultCallReturn.modifiers == 0x1200)
    for primary in InteractionMode.allCases {
        settings.primaryMode = primary
        let initial = settings.secondaryMode
        settings.cycleSecondaryMode(forward: true)
        #expect(settings.primaryMode == primary)
        #expect(settings.secondaryMode != primary && settings.secondaryMode != initial)
        settings.cycleSecondaryMode(forward: false)
        #expect(settings.secondaryMode == initial)
    }
    settings.primaryMode = .callReturn
    settings.secondaryMode = .callReturn
    #expect(settings.primaryMode != settings.secondaryMode)
    let shortcut = HotKeyShortcut(keyCode: 15, modifiers: 0x1200)
    settings.callReturnShortcut = shortcut
    let reloaded = ScreenSwapSettings(defaults: defaults)
    #expect(reloaded.primaryMode == settings.primaryMode)
    #expect(reloaded.secondaryMode == .callReturn)
    #expect(reloaded.callReturnShortcut == shortcut)
    defaults.set("invalid", forKey: "ScreenSwap.primaryMode")
    defaults.set("invalid", forKey: "ScreenSwap.secondaryMode")
    #expect(settings.primaryMode == .swap && settings.secondaryMode == .move)
}

@MainActor
private final class SettingsAuthorization: AccessibilityAuthorizing {
    var isTrusted: Bool { true }
    func requestAccess() {}
}

@Test @MainActor
func shortcutConfigurationRejectsCollisionsAndRestoresFailedRegistration() {
    let suite = "ScreenSwapTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = ScreenSwapSettings(defaults: defaults)
    var calls: [HotKeyShortcut] = []
    var succeeds = false
    let actions = SettingsActions(settings: settings, authorization: SettingsAuthorization(),
        accessibilityStatus: NSTextField(labelWithString: ""), shortcutStatus: NSTextField(labelWithString: ""),
        shortcutRegistration: { calls.append($0); return succeeds },
        moveShortcutStatus: NSTextField(labelWithString: ""),
        moveShortcutRegistration: { calls.append($0); return succeeds },
        callReturnStatus: NSTextField(labelWithString: ""),
        callReturnShortcutRegistration: { calls.append($0); return succeeds })
    #expect(!actions.replaceCallReturnShortcut(settings.shortcut))
    #expect(!actions.replaceCallReturnShortcut(settings.moveShortcut))
    #expect(!actions.replaceShortcut(settings.callReturnShortcut))
    #expect(!actions.replaceMoveShortcut(settings.callReturnShortcut))
    #expect(!actions.replaceCallReturnShortcut(HotKeyShortcut(keyCode: 8, modifiers: 0)))
    #expect(calls.isEmpty)
    let replacement = HotKeyShortcut(keyCode: 15, modifiers: 0x1200)
    #expect(!actions.replaceCallReturnShortcut(replacement))
    #expect(calls == [replacement, .defaultCallReturn])
    #expect(settings.callReturnShortcut == .defaultCallReturn)
    succeeds = true
    #expect(actions.replaceCallReturnShortcut(replacement))
    #expect(settings.callReturnShortcut == replacement)
}


@Test @MainActor
func existingSwapMovePreferenceMigratesWithoutChangingClickBindings() {
    let suiteName = "ScreenSwapTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("move", forKey: "ScreenSwap.defaultClickMode")
    let settings = ScreenSwapSettings(defaults: defaults)
    #expect(settings.primaryMode == .move && settings.secondaryMode == .swap)
    settings.cycleSecondaryMode(forward: true)
    #expect(settings.primaryMode == .move && settings.secondaryMode == .callReturn)
    settings.primaryMode = .callReturn
    let reloaded = ScreenSwapSettings(defaults: defaults)
    #expect(reloaded.primaryMode == .callReturn && reloaded.secondaryMode == .move)
}
