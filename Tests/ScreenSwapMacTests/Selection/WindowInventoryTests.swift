import CoreGraphics
import ScreenSwapCore
import Testing
@testable import ScreenSwapMac

@Test
func inventoryClassifiesPositiveAreaSpanningButNotBoundaryTouching() {
    let displays = [
        DisplaySnapshot(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100)),
        DisplaySnapshot(id: 2, frame: CGRect(x: 100, y: 0, width: 100, height: 100), visibleFrame: CGRect(x: 100, y: 0, width: 100, height: 100))
    ]
    #expect(WindowInventoryClassifier.spans(CGRect(x: 90, y: 10, width: 20, height: 20), displays: displays))
    #expect(!WindowInventoryClassifier.spans(CGRect(x: 0, y: 10, width: 100, height: 20), displays: displays))
    #expect(WindowInventoryClassifier.owner(of: CGRect(x: 90, y: 10, width: 20, height: 20), displays: displays) == 1)
}

@Test
func inventoryDisplayUsesStableOrderAndNameFallback() {
    let second = InventoryDisplay(
        snapshot: DisplaySnapshot(id: 9, frame: .zero, visibleFrame: .zero),
        ordinal: 2,
        name: nil
    )
    let first = InventoryDisplay(
        snapshot: DisplaySnapshot(id: 3, frame: .zero, visibleFrame: .zero),
        ordinal: 1,
        name: "Built-in Retina Display"
    )
    let inventory = WindowInventory(displays: [second, first], windows: [])
    #expect(inventory.displays.map(\.snapshot.id) == [3, 9])
    #expect(first.label == "1 — Built-in Retina Display")
    #expect(second.label == "Display 2")
}

@Test
func inventoryLabelsNeverBecomeIdentityAndHaveDeterministicFallbacks() {
    #expect(WindowInventoryClassifier.label(applicationName: "Finder", title: "Desktop", ordinal: 1) == "Finder — Desktop")
    #expect(WindowInventoryClassifier.label(applicationName: "Finder", title: nil, ordinal: 2) == "Finder — Window 2")
    #expect(WindowInventoryClassifier.label(applicationName: nil, title: nil, ordinal: 3) == "Window 3")
}
