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

@MainActor
public final class LiveDisplayProvider: DisplayProviding {
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
}
