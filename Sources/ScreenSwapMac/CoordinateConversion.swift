import CoreGraphics
import ScreenSwapCore

/// Converts AppKit's global screen coordinates to Quartz/Accessibility global coordinates.
/// Both systems use the same X axis; their Y origins are opposite.
public struct AppKitCoordinateConverter: Sendable {
    public let mainDisplayHeight: CGFloat

    public init(mainDisplayHeight: CGFloat) {
        self.mainDisplayHeight = mainDisplayHeight
    }

    public func quartzRect(from appKitRect: CGRect) -> CGRect {
        CGRect(
            x: appKitRect.minX,
            y: mainDisplayHeight - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }
}

/// The AppKit data required to derive an AX/Quartz display snapshot without
/// retaining a live `NSScreen`. Keeping this value pure makes the choice of
/// coordinate reference display independently testable.
public struct AppKitDisplayGeometry: Equatable, Sendable {
    public let id: UInt32
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Builds AX/Quartz snapshots using the stable Quartz primary display as the
/// Y-axis reference. `NSScreen.main` is intentionally not used here: it can
/// change with the active/menu-bar screen, which is incorrect when displays
/// have different heights.
public enum AppKitDisplaySnapshotFactory {
    public static func makeSnapshots(
        from screens: [AppKitDisplayGeometry],
        primaryDisplayID: UInt32
    ) throws -> [DisplaySnapshot] {
        guard let primaryDisplay = screens.first(where: { $0.id == primaryDisplayID }) else {
            throw DisplayProviderError.noMainDisplay
        }
        let converter = AppKitCoordinateConverter(mainDisplayHeight: primaryDisplay.frame.height)
        return try screens.map { screen in
            guard screen.id != 0 else {
                throw DisplayProviderError.invalidScreenIdentifier
            }
            return DisplaySnapshot(
                id: screen.id,
                frame: converter.quartzRect(from: screen.frame),
                visibleFrame: converter.quartzRect(from: screen.visibleFrame)
            )
        }
        .sorted { $0.id < $1.id }
    }
}
