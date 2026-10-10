import Foundation

public enum InteractionMode: String, CaseIterable, Sendable {
    case swap, move, callReturn

    public var title: String {
        switch self {
        case .swap: "Swap"
        case .move: "Move Focused Window"
        case .callReturn: "Call / Return"
        }
    }
}
