import Testing
import ScreenSwapMac

@Test
func macIntegrationModuleImportsWithoutCreatingStatusItem() {
    let converter = AppKitCoordinateConverter(mainDisplayHeight: 900)
    #expect(converter.quartzRect(from: .init(x: 0, y: 0, width: 10, height: 10)).origin.y == 890)
}
