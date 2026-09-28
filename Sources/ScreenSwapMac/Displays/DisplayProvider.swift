import AppKit
import CoreGraphics
import ScreenSwapCore

public enum DisplayProviderError: Error, Equatable, Sendable {
    case noMainDisplay
    case missingScreenIdentifier
    case invalidScreenIdentifier
}

@MainActor
public protocol DisplayProviding: AnyObject {
    func currentDisplays() throws -> [DisplaySnapshot]
}

/// Optional presentation metadata for the menu. Geometry continues to use
/// only `DisplaySnapshot`; a display name is never an identity.
@MainActor
public protocol DisplayInventoryProviding: AnyObject {
    func currentInventoryDisplays() throws -> [InventoryDisplay]
}

@MainActor
public final class LiveDisplayProvider: DisplayProviding, DisplayInventoryProviding {
    public init() {}

    public func currentDisplays() throws -> [DisplaySnapshot] {
        let screenGeometries = try NSScreen.screens.map { screen -> AppKitDisplayGeometry in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                throw DisplayProviderError.missingScreenIdentifier
            }
            let id = number.uint32Value
            guard id != 0 else {
                throw DisplayProviderError.invalidScreenIdentifier
            }
            return AppKitDisplayGeometry(
                id: id,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        return try AppKitDisplaySnapshotFactory.makeSnapshots(
            from: screenGeometries,
            primaryDisplayID: CGMainDisplayID()
        )
    }

    public func currentInventoryDisplays() throws -> [InventoryDisplay] {
        let screens = NSScreen.screens
        let snapshots = try currentDisplays()
        let namesByID = try Dictionary(uniqueKeysWithValues: screens.map { screen -> (UInt32, String?) in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                throw DisplayProviderError.missingScreenIdentifier
            }
            return (number.uint32Value, screen.localizedName)
        })
        return snapshots.sorted { $0.id < $1.id }.enumerated().map { offset, snapshot in
            InventoryDisplay(snapshot: snapshot, ordinal: offset + 1, name: namesByID[snapshot.id] ?? nil)
        }
    }
}
