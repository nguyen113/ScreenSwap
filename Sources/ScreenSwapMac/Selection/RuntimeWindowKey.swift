import Foundation

/// Stable only for one running window-server session. This deliberately keeps
/// selection state separate from transaction-local `WindowID` and AX handles.
public struct RuntimeWindowKey: Hashable, Sendable {
    public let processIdentifier: Int32
    public let quartzWindowNumber: UInt32

    public init(processIdentifier: Int32, quartzWindowNumber: UInt32) {
        self.processIdentifier = processIdentifier
        self.quartzWindowNumber = quartzWindowNumber
    }
}
