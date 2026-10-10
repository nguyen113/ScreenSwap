import ScreenSwapCore
import CoreGraphics

public enum MoveArrowDirection: String, CaseIterable, Sendable {
    case left, right, up, down, upLeft, upRight, downLeft, downRight

    public var symbolName: String {
        switch self {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .upLeft: "arrow.up.left"
        case .upRight: "arrow.up.right"
        case .downLeft: "arrow.down.left"
        case .downRight: "arrow.down.right"
        }
    }

    public static func resolve(activeFrame: CGRect, displays: [DisplaySnapshot], pair: Set<UInt32>) -> Self? {
        guard pair.count == 2,
              !WindowInventoryClassifier.spans(activeFrame, displays: displays),
              let sourceID = WindowInventoryClassifier.owner(of: activeFrame, displays: displays),
              pair.contains(sourceID),
              let source = displays.first(where: { $0.id == sourceID }),
              let destination = displays.first(where: { pair.contains($0.id) && $0.id != sourceID }) else { return nil }
        let dx = destination.frame.midX - source.frame.midX
        let dy = destination.frame.midY - source.frame.midY
        // Quartz y increases downwards. Small display offsets should still
        // appear horizontal or vertical; diagonal arrangements get diagonals.
        if abs(dy) <= abs(dx) * 0.4 { return dx < 0 ? .left : .right }
        if abs(dx) <= abs(dy) * 0.4 { return dy < 0 ? .up : .down }
        if dy < 0 { return dx < 0 ? .upLeft : .upRight }
        return dx < 0 ? .downLeft : .downRight
    }
}
