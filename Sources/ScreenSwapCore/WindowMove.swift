import Foundation
import CoreGraphics

public struct WindowMove: Equatable, Sendable {
    public let windowID: WindowID
    public let destinationDisplayID: UInt32
    public let frame: CGRect

    public init(windowID: WindowID, destinationDisplayID: UInt32, frame: CGRect) {
        self.windowID = windowID
        self.destinationDisplayID = destinationDisplayID
        self.frame = frame
    }
}
