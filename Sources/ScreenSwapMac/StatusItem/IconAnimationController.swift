import AppKit

public enum StatusIconState: Equatable, Sendable { case idle, hoverSwap, executingSwap }

@MainActor
public final class IconAnimationController {
    public private(set) var state: StatusIconState = .idle
    private var playedForCurrentHover = false
    public init() {}
    /// Returns whether this pointer visit should play the one-shot motion
    /// effect. Reduce Motion still exposes a hover state for a static visual
    /// treatment, but never requests movement or opacity animation.
    @discardableResult
    public func pointerEntered(reduceMotion: Bool) -> Bool {
        guard !playedForCurrentHover else { return false }
        playedForCurrentHover = true
        state = .hoverSwap
        return !reduceMotion
    }
    public func pointerExited() { playedForCurrentHover = false; state = .idle }
    public func beganSwap() { state = .executingSwap }
    public func endedSwap() { state = .idle }
}
