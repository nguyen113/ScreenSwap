import ScreenSwapCore

/// ScreenSwap's display role never changes the physical Quartz coordinate
/// origin. Display discovery must continue to use macOS's primary display.
public enum PrimaryDisplaySelection {
    public static func resolve(
        preferredDisplayID: UInt32?,
        systemPrimaryDisplayID: UInt32?,
        activeDisplays: [DisplaySnapshot]
    ) -> UInt32? {
        let activeIDs = Set(activeDisplays.map(\.id))
        if let preferredDisplayID, activeIDs.contains(preferredDisplayID) { return preferredDisplayID }
        if let systemPrimaryDisplayID, activeIDs.contains(systemPrimaryDisplayID) { return systemPrimaryDisplayID }
        return activeIDs.min()
    }
}
