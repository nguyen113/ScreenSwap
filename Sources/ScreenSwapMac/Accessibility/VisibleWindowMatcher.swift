import CoreGraphics
import Foundation

/// A non-sensitive record from Quartz's on-screen window list. Quartz and AX
/// both use the global Quartz coordinate system for these bounds.
public struct VisibleWindowSnapshot: Equatable, Sendable {
    public let processIdentifier: Int32
    public let frame: CGRect
    /// Quartz's opaque window-server number. It is used only to preserve
    /// in-memory presentation intent across consecutive captures.
    public let windowNumber: UInt32?

    public init(processIdentifier: Int32, frame: CGRect, windowNumber: UInt32? = nil) {
        self.processIdentifier = processIdentifier
        self.frame = frame
        self.windowNumber = windowNumber
    }
}

/// Matches an AX frame to one Quartz window without depending on a title or an
/// AX identifier. A capture consumes a matched record so one on-screen Quartz
/// window can never make multiple AX elements eligible.
public enum VisibleWindowMatcher {
    public static func matchIndex(
        processIdentifier: Int32,
        frame: CGRect,
        candidates: [VisibleWindowSnapshot]
    ) -> Int? {
        var best: (index: Int, score: CGFloat)?

        for (index, candidate) in candidates.enumerated() where candidate.processIdentifier == processIdentifier {
            let score = similarityScore(axFrame: frame, quartzFrame: candidate.frame)
            guard score > 0, best == nil || score > best!.score else { continue }
            best = (index, score)
        }
        return best?.index
    }

    private static func similarityScore(axFrame: CGRect, quartzFrame: CGRect) -> CGFloat {
        guard !axFrame.isEmpty, !quartzFrame.isEmpty else { return 0 }

        let intersection = axFrame.intersection(quartzFrame)
        let smallerArea = min(axFrame.width * axFrame.height, quartzFrame.width * quartzFrame.height)
        let overlap = intersection.isNull || smallerArea <= 0 ? 0 : (intersection.width * intersection.height) / smallerArea
        if overlap >= 0.60 {
            return overlap
        }

        // Window-server bounds can differ from AX bounds by a shadow or title
        // bar. Permit a small origin/size delta as a second, conservative path.
        let originDelta = max(
            abs(axFrame.minX - quartzFrame.minX),
            abs(axFrame.minY - quartzFrame.minY)
        )
        let sizeDelta = max(
            abs(axFrame.width - quartzFrame.width),
            abs(axFrame.height - quartzFrame.height)
        )
        guard originDelta <= 24, sizeDelta <= 48 else { return 0 }
        return 0.50 - (originDelta + sizeDelta) / 1_000
    }
}
