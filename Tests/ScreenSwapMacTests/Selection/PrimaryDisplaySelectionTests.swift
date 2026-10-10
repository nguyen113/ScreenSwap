import CoreGraphics
import Foundation
import ScreenSwapCore
import Testing
@testable import ScreenSwapMac

private func primaryDisplays(_ ids: [UInt32]) -> [DisplaySnapshot] {
    ids.enumerated().map { offset, id in
        let frame = CGRect(x: CGFloat(offset * 1000), y: -200, width: 1000, height: 800)
        return DisplaySnapshot(id: id, frame: frame, visibleFrame: frame)
    }
}

@Test @MainActor
func primaryDisplayPreferencePersistsAndResetFollowsMacOS() {
    let suite = "ScreenSwapTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = ScreenSwapSettings(defaults: defaults)
    #expect(settings.preferredPrimaryDisplayID == nil)
    settings.preferredPrimaryDisplayID = UInt32.max
    let reloaded = ScreenSwapSettings(defaults: defaults)
    #expect(reloaded.preferredPrimaryDisplayID == UInt32.max)
    reloaded.preferredPrimaryDisplayID = nil
    #expect(settings.preferredPrimaryDisplayID == nil)
    for invalid in [-1, 0, Int64(UInt32.max) + 1] {
        defaults.set(NSNumber(value: invalid), forKey: "ScreenSwap.primaryDisplayID")
        #expect(settings.preferredPrimaryDisplayID == nil)
    }
}

@Test
func primaryDisplayResolutionUsesStableIdentityWithoutChangingCoordinates() {
    let displays = primaryDisplays([90, 3, 25])
    #expect(PrimaryDisplaySelection.resolve(preferredDisplayID: 25, systemPrimaryDisplayID: 90,
        activeDisplays: Array(displays.reversed())) == 25)
    #expect(PrimaryDisplaySelection.resolve(preferredDisplayID: nil, systemPrimaryDisplayID: 90,
        activeDisplays: displays) == 90)
    #expect(PrimaryDisplaySelection.resolve(preferredDisplayID: 25, systemPrimaryDisplayID: 90,
        activeDisplays: Array(displays.prefix(2))) == 90)
    #expect(PrimaryDisplaySelection.resolve(preferredDisplayID: 25, systemPrimaryDisplayID: 999,
        activeDisplays: Array(displays.prefix(2))) == 3)
    #expect(PrimaryDisplaySelection.resolve(preferredDisplayID: 25, systemPrimaryDisplayID: 90,
        activeDisplays: []) == nil)
    #expect(displays[0].frame.minY == -200 && displays[2].frame.minX == 2000)
}

@MainActor private final class PrimaryAuthorization: AccessibilityAuthorizing {
    var isTrusted = true
    func requestAccess() {}
}

@MainActor private final class PrimaryDisplays: DisplayProviding, PrimaryDisplayProviding {
    var values = primaryDisplays([90, 3, 25])
    var reads = 0
    var primaryReads = 0
    func currentDisplays() throws -> [DisplaySnapshot] { reads += 1; return values }
    func primaryDisplayID() -> UInt32 { primaryReads += 1; return 90 }
}

@MainActor private final class PrimaryWindows: WindowInventoryProviding {
    var reads = 0
    func inventory(displays: [InventoryDisplay]) -> WindowInventory {
        reads += 1
        return WindowInventory(displays: displays, windows: [])
    }
}

@Test @MainActor
func liveInventorySharesPrimaryOverrideAndRetainsItAcrossDisconnect() {
    let suite = "ScreenSwapTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = ScreenSwapSettings(defaults: defaults)
    settings.preferredPrimaryDisplayID = 25
    let displays = PrimaryDisplays()
    let provider = LiveStatusItemInventoryProvider(authorization: PrimaryAuthorization(), displays: displays,
        windows: PrimaryWindows(), displaySelection: DisplayPairSelectionStore(), settings: settings)
    let inventory = provider.currentInventory()
    #expect(inventory.primaryDisplayID == 25 && inventory.systemPrimaryDisplayID == 90)
    #expect(inventory.selectedDisplayIDs.contains(25))
    #expect(inventory.displays.map(\.snapshot) == displays.values.sorted { $0.id < $1.id })
    displays.values.removeLast()
    #expect(provider.currentInventory().primaryDisplayID == 90)
    #expect(settings.preferredPrimaryDisplayID == 25)
    displays.values = primaryDisplays([90, 3, 25])
    #expect(provider.currentInventory().primaryDisplayID == 25)
}

@Test @MainActor
func primaryInventoryChecksPermissionBeforeDisplayAndWindowReads() {
    let authorization = PrimaryAuthorization()
    authorization.isTrusted = false
    let displays = PrimaryDisplays()
    let windows = PrimaryWindows()
    let provider = LiveStatusItemInventoryProvider(authorization: authorization, displays: displays,
        windows: windows, displaySelection: DisplayPairSelectionStore())
    #expect(provider.currentInventory() == .permissionRequired)
    #expect(displays.reads == 0 && displays.primaryReads == 0 && windows.reads == 0)
}
