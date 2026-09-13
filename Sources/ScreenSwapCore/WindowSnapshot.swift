import Foundation
import CoreGraphics

public struct WindowID: Hashable, Sendable {
    public let processIdentifier: Int32
    public let accessibilityIdentifier: String

    public init(processIdentifier: Int32, accessibilityIdentifier: String) {
        self.processIdentifier = processIdentifier
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

public struct WindowSnapshot: Equatable, Sendable {
    public let id: WindowID
    public let sourceDisplayID: UInt32
    public let frame: CGRect

    public init(id: WindowID, sourceDisplayID: UInt32, frame: CGRect) {
        self.id = id
        self.sourceDisplayID = sourceDisplayID
        self.frame = frame
    }
}
