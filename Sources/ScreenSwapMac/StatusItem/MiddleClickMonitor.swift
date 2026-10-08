import AppKit
import CoreGraphics

enum MiddleClickOutcome: Equatable {
    case ignored
    case move(RuntimeWindowKey?)
}

/// A middle click must start and finish on the status item. Capture focus at
/// mouse-down so interacting with the menu bar cannot retarget the command.
struct MiddleClickGesture {
    private var beganOverIcon = false
    private var focusedKey: RuntimeWindowKey?

    mutating func begin(buttonNumber: Int, point: CGPoint, iconFrame: CGRect, focusedKey: RuntimeWindowKey?) {
        beganOverIcon = buttonNumber == 2 && iconFrame.contains(point)
        self.focusedKey = beganOverIcon ? focusedKey : nil
    }

    mutating func end(buttonNumber: Int, point: CGPoint, iconFrame: CGRect) -> MiddleClickOutcome {
        defer { beganOverIcon = false; focusedKey = nil }
        guard buttonNumber == 2, beganOverIcon, iconFrame.contains(point) else { return .ignored }
        return .move(focusedKey)
    }
}

@MainActor
final class MiddleClickMonitor {
    private let iconFrame: () -> CGRect?
    private let focusedWindowKey: () -> RuntimeWindowKey?
    private let onClick: (RuntimeWindowKey?) -> Void
    private var gesture = MiddleClickGesture()
    nonisolated(unsafe) private var monitors: [Any] = []

    init(
        iconFrame: @escaping () -> CGRect?,
        focusedWindowKey: @escaping () -> RuntimeWindowKey?,
        onClick: @escaping (RuntimeWindowKey?) -> Void
    ) {
        self.iconFrame = iconFrame
        self.focusedWindowKey = focusedWindowKey
        self.onClick = onClick
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.otherMouseDown, .otherMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    deinit {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ event: NSEvent) {
        let point = event.cgEvent?.location ?? quartzMouseLocation()
        switch event.type {
        case .otherMouseDown:
            let frame = iconFrame() ?? .null
            gesture.begin(
                buttonNumber: event.buttonNumber,
                point: point,
                iconFrame: frame,
                focusedKey: event.buttonNumber == 2 && frame.contains(point) ? focusedWindowKey() : nil
            )
        case .otherMouseUp:
            let outcome = gesture.end(
                buttonNumber: event.buttonNumber,
                point: point,
                iconFrame: iconFrame() ?? .null
            )
            if case let .move(key) = outcome { onClick(key) }
        default:
            break
        }
    }

    private func quartzMouseLocation() -> CGPoint {
        let appKitPoint = NSEvent.mouseLocation
        return CGPoint(
            x: appKitPoint.x,
            y: CGDisplayBounds(CGMainDisplayID()).height - appKitPoint.y
        )
    }
}
