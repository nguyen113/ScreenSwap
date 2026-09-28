import CoreGraphics
import ScreenSwapCore
import Testing
@testable import ScreenSwapMac

@Test
func coordinateConversionCoversMainRightAboveBelowAndInsets() {
    let converter = AppKitCoordinateConverter(mainDisplayHeight: 1000)
    #expect(converter.quartzRect(from: CGRect(x: 0, y: 100, width: 800, height: 900)) == CGRect(x: 0, y: 0, width: 800, height: 900))
    #expect(converter.quartzRect(from: CGRect(x: 800, y: 100, width: 1200, height: 900)) == CGRect(x: 800, y: 0, width: 1200, height: 900))
    #expect(converter.quartzRect(from: CGRect(x: 0, y: 1000, width: 800, height: 900)) == CGRect(x: 0, y: -900, width: 800, height: 900))
    #expect(converter.quartzRect(from: CGRect(x: 0, y: -800, width: 800, height: 800)) == CGRect(x: 0, y: 1000, width: 800, height: 800))
    #expect(converter.quartzRect(from: CGRect(x: 20, y: 120, width: 760, height: 760)) == CGRect(x: 20, y: 120, width: 760, height: 760))
}

@Test
func displaySnapshotsUseStableQuartzPrimaryInsteadOfActiveScreen() throws {
    // The physically primary display is 1080 points high. The shorter display
    // can be the active AppKit screen, but it must never become the Y-axis
    // reference for AX window coordinates.
    let snapshots = try AppKitDisplaySnapshotFactory.makeSnapshots(
        from: [
            AppKitDisplayGeometry(
                id: 1,
                frame: CGRect(x: 1920, y: 13, width: 1280, height: 800),
                visibleFrame: CGRect(x: 1920, y: 13, width: 1280, height: 800)
            ),
            AppKitDisplayGeometry(
                id: 3,
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 82, width: 1920, height: 968)
            )
        ],
        primaryDisplayID: 3
    )

    #expect(snapshots == [
        DisplaySnapshot(
            id: 1,
            frame: CGRect(x: 1920, y: 267, width: 1280, height: 800),
            visibleFrame: CGRect(x: 1920, y: 267, width: 1280, height: 800)
        ),
        DisplaySnapshot(
            id: 3,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 968)
        )
    ])
}
