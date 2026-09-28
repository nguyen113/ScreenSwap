import Testing
@testable import ScreenSwapMac

@Test
@MainActor
func selectionStoreDefaultsNewKeysToSelectedAndDropsStaleKeys() {
    let store = WindowSelectionStore()
    let first = RuntimeWindowKey(processIdentifier: 1, quartzWindowNumber: 1)
    let second = RuntimeWindowKey(processIdentifier: 1, quartzWindowNumber: 2)
    store.reconcile([first, second])
    store.setSelected(false, for: first)
    store.reconcile([second])
    #expect(store.snapshot() == [second])
    store.reconcile([first, second])
    #expect(store.isSelected(first))
}

@Test
@MainActor
func selectionStoreReportsCheckedUncheckedAndMixedGroupState() {
    let store = WindowSelectionStore()
    let first = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 1)
    let second = RuntimeWindowKey(processIdentifier: 10, quartzWindowNumber: 2)
    let keys: Set<RuntimeWindowKey> = [first, second]
    store.reconcile(keys)
    #expect(store.selectionState(for: keys) == .on)
    store.setSelected(false, for: first)
    #expect(store.selectionState(for: keys) == .mixed)
    store.setSelected(false, for: second)
    #expect(store.selectionState(for: keys) == .off)
    #expect(store.selectionState(for: []) == .off)
}
