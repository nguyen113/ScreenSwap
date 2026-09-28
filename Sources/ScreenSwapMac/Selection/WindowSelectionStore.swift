import Foundation

public enum WindowSelectionState: Equatable, Sendable {
    case off
    case on
    case mixed
}

/// Runtime-only selection choices. Keys use a Quartz window-server number, so
/// titles and transaction-local AX IDs never become selection identity.
@MainActor
public final class WindowSelectionStore {
    private var selected: [RuntimeWindowKey: Bool] = [:]

    public init() {}

    /// Reconciles the current inventory. New keys default to selected; vanished
    /// keys are discarded, preventing a later PID/label reuse from inheriting
    /// a stale user choice.
    public func reconcile(_ keys: Set<RuntimeWindowKey>) {
        selected = keys.reduce(into: [:]) { state, key in
            state[key] = selected[key] ?? true
        }
    }

    public func isSelected(_ key: RuntimeWindowKey) -> Bool { selected[key] ?? true }

    public func setSelected(_ isSelected: Bool, for key: RuntimeWindowKey) {
        selected[key] = isSelected
    }

    public func setSelected(_ isSelected: Bool, for keys: Set<RuntimeWindowKey>) {
        for key in keys { selected[key] = isSelected }
    }

    public func selectionState(for keys: Set<RuntimeWindowKey>) -> WindowSelectionState {
        guard !keys.isEmpty else { return .off }
        let selectedCount = keys.reduce(into: 0) { count, key in
            if isSelected(key) { count += 1 }
        }
        if selectedCount == 0 { return .off }
        return selectedCount == keys.count ? .on : .mixed
    }

    public func snapshot() -> Set<RuntimeWindowKey> {
        Set(selected.compactMap { $0.value ? $0.key : nil })
    }
}

public protocol SwapSelectionProviding: AnyObject {
    @MainActor func reconcile(_ keys: Set<RuntimeWindowKey>)
    @MainActor func frozenSelectedKeys() -> Set<RuntimeWindowKey>
}

extension WindowSelectionStore: SwapSelectionProviding {
    public func frozenSelectedKeys() -> Set<RuntimeWindowKey> { snapshot() }
}
