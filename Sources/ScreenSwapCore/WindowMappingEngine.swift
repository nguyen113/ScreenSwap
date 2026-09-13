import Foundation

public struct WindowMappingEngine: Sendable {
    public init() {}

    public func normalize(
        windowFrame: CGRect,
        in sourceVisibleFrame: CGRect
    ) -> NormalizedWindowGeometry {
        NormalizedWindowGeometry(
            x: (windowFrame.minX - sourceVisibleFrame.minX) / sourceVisibleFrame.width,
            y: (windowFrame.minY - sourceVisibleFrame.minY) / sourceVisibleFrame.height,
            width: windowFrame.width / sourceVisibleFrame.width,
            height: windowFrame.height / sourceVisibleFrame.height
        )
    }

    public func project(
        normalized: NormalizedWindowGeometry,
        onto destinationVisibleFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: destinationVisibleFrame.minX + normalized.x * destinationVisibleFrame.width,
            y: destinationVisibleFrame.minY + normalized.y * destinationVisibleFrame.height,
            width: normalized.width * destinationVisibleFrame.width,
            height: normalized.height * destinationVisibleFrame.height
        )
    }

    public func clamp(
        frame: CGRect,
        to destinationVisibleFrame: CGRect
    ) -> CGRect {
        let width = min(max(frame.width, 0), destinationVisibleFrame.width)
        let height = min(max(frame.height, 0), destinationVisibleFrame.height)

        let maxX = destinationVisibleFrame.maxX - width
        let maxY = destinationVisibleFrame.maxY - height

        let x = min(
            max(frame.minX, destinationVisibleFrame.minX),
            maxX
        )
        let y = min(
            max(frame.minY, destinationVisibleFrame.minY),
            maxY
        )

        return CGRect(x: x, y: y, width: width, height: height)
    }

    public func sourceDisplayID(
        for windowFrame: CGRect,
        displayA: DisplaySnapshot,
        displayB: DisplaySnapshot
    ) -> UInt32 {
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)

        let inA = containsInclusive(center, in: displayA.frame)
        let inB = containsInclusive(center, in: displayB.frame)

        // A wins an exact shared-boundary/tie case deterministically.
        if inA {
            return displayA.id
        }
        if inB {
            return displayB.id
        }

        // The benchmark contract supplies resolvable two-display geometry.
        // Keep a deterministic fallback for malformed/out-of-contract input.
        let distanceA = squaredDistance(center, to: centerPoint(of: displayA.frame))
        let distanceB = squaredDistance(center, to: centerPoint(of: displayB.frame))
        return distanceA <= distanceB ? displayA.id : displayB.id
    }

    public func makeSwapMoves(
        windows: [WindowSnapshot],
        displayA: DisplaySnapshot,
        displayB: DisplaySnapshot
    ) -> [WindowMove] {
        windows.compactMap { window in
            if spansBothDisplays(
                window.frame,
                displayA: displayA,
                displayB: displayB
            ) {
                return nil
            }

            let source: DisplaySnapshot
            let destination: DisplaySnapshot

            if window.sourceDisplayID == displayA.id {
                source = displayA
                destination = displayB
            } else if window.sourceDisplayID == displayB.id {
                source = displayB
                destination = displayA
            } else {
                return nil
            }

            let normalized = normalize(
                windowFrame: window.frame,
                in: source.visibleFrame
            )
            let projected = project(
                normalized: normalized,
                onto: destination.visibleFrame
            )
            let clamped = clamp(
                frame: projected,
                to: destination.visibleFrame
            )

            return WindowMove(
                windowID: window.id,
                destinationDisplayID: destination.id,
                frame: clamped
            )
        }
    }


    private func spansBothDisplays(
        _ windowFrame: CGRect,
        displayA: DisplaySnapshot,
        displayB: DisplaySnapshot
    ) -> Bool {
        hasPositiveAreaIntersection(windowFrame, displayA.frame) &&
        hasPositiveAreaIntersection(windowFrame, displayB.frame)
    }

    private func hasPositiveAreaIntersection(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let overlap = lhs.intersection(rhs)
        return !overlap.isNull && overlap.width > 0 && overlap.height > 0
    }

    private func containsInclusive(_ point: CGPoint, in rect: CGRect) -> Bool {
        point.x >= rect.minX &&
        point.x <= rect.maxX &&
        point.y >= rect.minY &&
        point.y <= rect.maxY
    }

    private func centerPoint(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private func squaredDistance(_ lhs: CGPoint, to rhs: CGPoint) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}
