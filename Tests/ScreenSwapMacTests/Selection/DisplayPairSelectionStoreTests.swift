import CoreGraphics
import ScreenSwapCore
import Testing
@testable import ScreenSwapMac

private func pairDisplays(_ ids: [UInt32]) -> [DisplaySnapshot] {
    ids.enumerated().map { offset, id in
        let frame = CGRect(x: CGFloat(offset * 1_000), y: 0, width: 1_000, height: 800)
        return DisplaySnapshot(id: id, frame: frame, visibleFrame: frame)
    }
}

@Test
@MainActor
func displayPairStoreAutomaticallySelectsBothDisplays() {
    let store = DisplayPairSelectionStore()
    store.reconcile(activeDisplays: pairDisplays([1, 2]), primaryDisplayID: 1, candidateCounts: [:])
    #expect(store.frozenPair() == [1, 2])
}

@Test
@MainActor
func displayPairStoreReplacesLeastUsefulAutomaticMemberOnFirstManualChange() {
    let store = DisplayPairSelectionStore()
    let displays = pairDisplays([1, 2, 3])
    store.reconcile(activeDisplays: displays, primaryDisplayID: 1, candidateCounts: [1: 6, 2: 2, 3: 1])
    #expect(store.frozenPair() == [1, 2])

    store.select(displayID: 3, activeDisplays: displays, primaryDisplayID: 1, candidateCounts: [1: 6, 2: 2, 3: 1])
    #expect(store.frozenPair() == [1, 3])
}

@Test
@MainActor
func displayPairStoreKeepsPrimaryOnAutomaticTieAndThenUsesManualOrder() {
    let store = DisplayPairSelectionStore()
    let displays = pairDisplays([1, 2, 3])
    store.reconcile(activeDisplays: displays, primaryDisplayID: 1, candidateCounts: [1: 2, 2: 2, 3: 2])
    store.select(displayID: 3, activeDisplays: displays, primaryDisplayID: 1, candidateCounts: [1: 2, 2: 2, 3: 2])
    #expect(store.frozenPair() == [1, 3])

    store.select(displayID: 2, activeDisplays: displays, primaryDisplayID: 1, candidateCounts: [1: 2, 2: 2, 3: 2])
    #expect(store.frozenPair() == [3, 2])
    store.select(displayID: 1, activeDisplays: displays, primaryDisplayID: 1, candidateCounts: [1: 2, 2: 2, 3: 2])
    #expect(store.frozenPair() == [2, 1])
}

@Test
@MainActor
func displayPairStorePreservesValidPairAndReplacesOnlyDisconnectedMember() {
    let store = DisplayPairSelectionStore()
    let initial = pairDisplays([1, 2, 3])
    store.reconcile(activeDisplays: initial, primaryDisplayID: 1, candidateCounts: [1: 4, 2: 3, 3: 1])
    #expect(store.frozenPair() == [1, 2])

    store.reconcile(activeDisplays: pairDisplays([1, 2, 3, 4]), primaryDisplayID: 1, candidateCounts: [1: 4, 2: 3, 3: 9, 4: 8])
    #expect(store.frozenPair() == [1, 2])
    store.reconcile(activeDisplays: pairDisplays([1, 3, 4]), primaryDisplayID: 1, candidateCounts: [1: 4, 3: 9, 4: 8])
    #expect(store.frozenPair() == [1, 3])
}

