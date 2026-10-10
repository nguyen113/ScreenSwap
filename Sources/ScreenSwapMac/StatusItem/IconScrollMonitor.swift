import AppKit
import CoreGraphics

/// A trackpad gesture cycles once; momentum never changes a binding. Wheel
/// events use a short debounce to avoid cycling twice on a single notch.
struct IconScrollGesture {
    private var preciseGestureActive = false
    private var lastStep: TimeInterval = -.infinity

    mutating func step(delta: CGFloat, precise: Bool, phase: NSEvent.Phase,
                       momentum: NSEvent.Phase, timestamp: TimeInterval) -> Bool? {
        if phase.contains(.ended) || phase.contains(.cancelled) { preciseGestureActive = false; return nil }
        guard momentum.isEmpty, abs(delta) > 0 else { return nil }
        if precise && !phase.isEmpty {
            guard !preciseGestureActive else { return nil }
            preciseGestureActive = true
        } else {
            guard timestamp - lastStep >= 0.2 else { return nil }
        }
        lastStep = timestamp
        return delta > 0
    }
}

@MainActor
final class IconScrollMonitor {
    private let iconFrame: () -> CGRect?
    private let cycle: (Bool) -> Void
    private let exit: () -> Void
    private var previewing = false
    private var gesture = IconScrollGesture()
    nonisolated(unsafe) private var monitors: [Any] = []

    init(iconFrame: @escaping () -> CGRect?, cycle: @escaping (Bool) -> Void, exit: @escaping () -> Void) {
        self.iconFrame = iconFrame
        self.cycle = cycle
        self.exit = exit
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .mouseMoved]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }) { monitors.append(local) }
    }

    deinit { for monitor in monitors { NSEvent.removeMonitor(monitor) } }

    private func handle(_ event: NSEvent) -> Bool {
        let point = event.cgEvent?.location ?? CGPoint(x: NSEvent.mouseLocation.x,
            y: CGDisplayBounds(CGMainDisplayID()).height - NSEvent.mouseLocation.y)
        guard iconFrame()?.contains(point) == true else {
            gesture = IconScrollGesture()
            if previewing { previewing = false; exit() }
            return false
        }
        guard event.type == .scrollWheel else { return false }
        if let forward = gesture.step(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
            phase: event.phase, momentum: event.momentumPhase, timestamp: event.timestamp) {
            previewing = true
            cycle(forward)
        }
        return true
    }
}
