import ScreenSwapCore

/// Runtime-only choice of the two displays that participate in a swap. This
/// deliberately has no persistence: display IDs can change as docks and
/// external displays reconnect.
@MainActor
public final class DisplayPairSelectionStore {
    private(set) var selectedDisplayIDs: Set<UInt32> = []
    private var manualSelectionOrder: [UInt32] = []

    public init() {}

    /// Reconciles a physical topology without replacing a still-valid pair.
    public func reconcile(
        activeDisplays: [DisplaySnapshot],
        primaryDisplayID: UInt32,
        candidateCounts: [UInt32: Int]
    ) {
        let activeIDs = Set(activeDisplays.map(\.id))
        guard activeIDs.count > 2 else {
            selectedDisplayIDs = activeIDs
            manualSelectionOrder = manualSelectionOrder.filter { activeIDs.contains($0) }
            return
        }

        let surviving = selectedDisplayIDs.intersection(activeIDs)
        if surviving.count == 2 {
            selectedDisplayIDs = surviving
            manualSelectionOrder = manualSelectionOrder.filter { surviving.contains($0) }
            return
        }

        if surviving.count == 1, let retained = surviving.first {
            let replacement = preferredDisplay(
                from: activeIDs.subtracting(surviving),
                primaryDisplayID: primaryDisplayID,
                candidateCounts: candidateCounts
            )!
            selectedDisplayIDs = [retained, replacement]
            manualSelectionOrder = manualSelectionOrder.filter { $0 == retained } + [replacement]
            return
        }

        let primary = activeIDs.contains(primaryDisplayID)
            ? primaryDisplayID
            : activeIDs.min()!
        let secondary = preferredDisplay(
            from: activeIDs.subtracting([primary]),
            primaryDisplayID: primaryDisplayID,
            candidateCounts: candidateCounts
        )!
        selectedDisplayIDs = [primary, secondary]
        // The automatic choice intentionally has no user selection order.
        manualSelectionOrder = []
    }

    /// Adds an unselected display and deterministically replaces one member of
    /// the pair. Selecting an already-selected display never produces an
    /// invalid one-display pair.
    public func select(
        displayID: UInt32,
        activeDisplays: [DisplaySnapshot],
        primaryDisplayID: UInt32,
        candidateCounts: [UInt32: Int]
    ) {
        reconcile(
            activeDisplays: activeDisplays,
            primaryDisplayID: primaryDisplayID,
            candidateCounts: candidateCounts
        )
        let activeIDs = Set(activeDisplays.map(\.id))
        guard activeIDs.count > 2,
              activeIDs.contains(displayID),
              !selectedDisplayIDs.contains(displayID) else { return }

        let removed: UInt32
        if manualSelectionOrder.count == 2,
           selectedDisplayIDs == Set(manualSelectionOrder) {
            removed = manualSelectionOrder[0]
        } else {
            removed = displayToReplaceFromAutomaticPair(
                primaryDisplayID: primaryDisplayID,
                candidateCounts: candidateCounts
            )
        }
        let retained = selectedDisplayIDs.subtracting([removed]).first!
        selectedDisplayIDs = [retained, displayID]
        manualSelectionOrder = [retained, displayID]
    }

    /// Returns a stable, frozen pair for one transaction. Manual order is
    /// retained where it exists; otherwise stable display-ID order is used.
    public func frozenPair() -> [UInt32] {
        if manualSelectionOrder.count == 2,
           Set(manualSelectionOrder) == selectedDisplayIDs {
            return manualSelectionOrder
        }
        return selectedDisplayIDs.sorted()
    }

    private func displayToReplaceFromAutomaticPair(
        primaryDisplayID: UInt32,
        candidateCounts: [UInt32: Int]
    ) -> UInt32 {
        selectedDisplayIDs.sorted { lhs, rhs in
            let lhsCount = candidateCounts[lhs, default: 0]
            let rhsCount = candidateCounts[rhs, default: 0]
            if lhsCount != rhsCount { return lhsCount < rhsCount }
            if lhs == primaryDisplayID { return false }
            if rhs == primaryDisplayID { return true }
            // Keep the lower stable ID on an unresolved tie.
            return lhs > rhs
        }.first!
    }

    private func preferredDisplay(
        from candidates: Set<UInt32>,
        primaryDisplayID: UInt32,
        candidateCounts: [UInt32: Int]
    ) -> UInt32? {
        candidates.sorted { lhs, rhs in
            let lhsCount = candidateCounts[lhs, default: 0]
            let rhsCount = candidateCounts[rhs, default: 0]
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            if lhs == primaryDisplayID { return true }
            if rhs == primaryDisplayID { return false }
            return lhs < rhs
        }.first
    }
}

