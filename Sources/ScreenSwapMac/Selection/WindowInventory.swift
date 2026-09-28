import CoreGraphics
import Foundation
import ScreenSwapCore

public struct InventoryWindow: Equatable, Sendable {
    /// A Quartz key exists only for windows currently represented by Quartz.
    /// Minimized and otherwise unavailable AX windows remain displayable, but
    /// cannot be selected for an imminent swap.
    public let key: RuntimeWindowKey?
    public let displayID: UInt32?
    public let label: String
    public let isSelectable: Bool
    public let isSpanning: Bool

    public init(key: RuntimeWindowKey?, displayID: UInt32?, label: String, isSelectable: Bool, isSpanning: Bool) {
        self.key = key; self.displayID = displayID; self.label = label
        self.isSelectable = isSelectable; self.isSpanning = isSpanning
    }
}

public struct InventoryDisplay: Equatable, Sendable {
    public let snapshot: DisplaySnapshot
    public let ordinal: Int
    public let name: String?

    public init(snapshot: DisplaySnapshot, ordinal: Int, name: String?) {
        self.snapshot = snapshot
        self.ordinal = ordinal
        self.name = name
    }

    public var label: String {
        let fallback = "Display \(ordinal)"
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return "\(ordinal) — \(name)"
    }
}

public struct WindowInventory: Equatable, Sendable {
    public let displays: [InventoryDisplay]
    public let windows: [InventoryWindow]
    public let isAuthorized: Bool

    public init(displays: [InventoryDisplay], windows: [InventoryWindow], isAuthorized: Bool = true) {
        self.displays = displays.sorted { $0.snapshot.id < $1.snapshot.id }
        self.windows = windows
        self.isAuthorized = isAuthorized
    }

    public static let permissionRequired = WindowInventory(displays: [], windows: [], isAuthorized: false)
    public var supportsSelection: Bool { isAuthorized && displays.count == 2 }
    public var spanningWindows: [InventoryWindow] { windows.filter(\.isSpanning) }
    public func windows(on displayID: UInt32) -> [InventoryWindow] {
        windows.filter { !$0.isSpanning && $0.displayID == displayID }
    }
}

@MainActor
public protocol WindowInventoryProviding: AnyObject {
    func inventory(displays: [InventoryDisplay]) -> WindowInventory
}

public enum WindowInventoryClassifier {
    public static func spans(_ frame: CGRect, displays: [DisplaySnapshot]) -> Bool {
        displays.filter { display in
            let overlap = frame.intersection(display.frame)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }.count > 1
    }

    public static func owner(of frame: CGRect, displays: [DisplaySnapshot]) -> UInt32? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        // Match the mapping engine's inclusive boundary behavior: the lower
        // stable ID wins a shared display edge instead of relying on AppKit's
        // half-open `CGRect.contains` implementation detail.
        return displays.sorted { $0.id < $1.id }.first {
            center.x >= $0.frame.minX && center.x <= $0.frame.maxX &&
                center.y >= $0.frame.minY && center.y <= $0.frame.maxY
        }?.id
    }

    public static func label(applicationName: String?, title: String?, ordinal: Int) -> String {
        let app = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (app?.isEmpty == false ? app : nil, window?.isEmpty == false ? window : nil) {
        case let (.some(app), .some(window)): return "\(app) — \(window)"
        case let (.some(app), .none): return "\(app) — Window \(ordinal)"
        case let (.none, .some(window)): return "Window \(ordinal) — \(window)"
        case (.none, .none): return "Window \(ordinal)"
        }
    }
}
