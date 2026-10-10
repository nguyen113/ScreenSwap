import AppKit
import ScreenSwapCore

enum StatusIconMode: String, CaseIterable {
    case swap = "Swap", moveLeft = "MoveLeft", moveRight = "MoveRight"

    var duration: Duration { self == .swap ? .milliseconds(200) : .milliseconds(180) }
    var templateName: String { rawValue + "Template" }

    /// The pack has no vertical glyph. Avoid a misleading horizontal arrow.
    static func move(from source: DisplaySnapshot, to destination: DisplaySnapshot) -> Self? {
        let dx = destination.frame.midX - source.frame.midX
        let dy = destination.frame.midY - source.frame.midY
        guard abs(dx) > abs(dy) else { return nil }
        return dx > 0 ? .moveRight : .moveLeft
    }
}

@MainActor
enum StatusIconImages {
    private static var cache: [String: NSImage] = [:]

    // SwiftPM executables use Bundle.module; packaged apps keep the same
    // resource bundle in Contents/Resources so it survives relocation.
    private static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("ScreenSwap_ScreenSwapMac.bundle"),
           let packaged = Bundle(url: url) { return packaged }
        return Bundle.module
    }()

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for scale in 1...2 {
            guard let url = bundle.url(forResource: "\(name)@\(scale)x", withExtension: "png", subdirectory: "StatusIcons"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { return nil }
            rep.size = image.size
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        cache[name] = image
        return image
    }

    static var appIcon: NSImage? {
        bundle.url(forResource: "AppIcon", withExtension: "png", subdirectory: "StatusIcons")
            .flatMap { NSImage(contentsOf: $0) }
    }
}

/// Presentation never delays a window transaction. Only a fully successful
/// action plays the pack's thirteen frames; every new state cancels playback.
@MainActor
final class IconAnimationController {
    private let setImage: (String) -> Void
    private let reduceMotion: () -> Bool
    private let waitUntil: (ContinuousClock.Instant) async throws -> Void
    private var observer: AccessibilityOptionsObservation?
    private var generation: UInt = 0
    private(set) var playback: Task<Void, Never>?
    private(set) var assetName = "SwapTemplate"
    private var settledMode: StatusIconMode = .swap
    private var available = true
    /// Re-evaluate the configured resting icon after playback (or its
    /// accessibility cancellation), using the current focused window.
    var onSettled: (() -> Void)?

    init(
        setImage: @escaping (String) -> Void,
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        observeAccessibility: Bool = true,
        waitUntil: @escaping (ContinuousClock.Instant) async throws -> Void = {
            try await Task.sleep(until: $0, clock: .continuous)
        }
    ) {
        self.setImage = setImage
        self.reduceMotion = reduceMotion
        self.waitUntil = waitUntil
        if observeAccessibility {
            let center = NSWorkspace.shared.notificationCenter
            let token = center.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.accessibilityOptionsChanged() }
            }
            observer = AccessibilityOptionsObservation(center: center, token: token)
        }
    }

    deinit {
        playback?.cancel()
    }

    func show(_ mode: StatusIconMode = .swap, available: Bool = true) {
        generation &+= 1
        playback?.cancel()
        playback = nil
        settledMode = mode
        self.available = available
        display(mode.rawValue + (available ? "Template" : "DisabledTemplate"))
    }

    func settle(after outcome: SwapOutcome, next: StatusIconMode = .swap) {
        let available: Bool
        switch outcome {
        case .noPermission, .unsupportedDisplayCount: available = false
        default: available = true
        }
        show(next, available: available)
    }

    func completed(_ mode: StatusIconMode, outcome: SwapOutcome, next: StatusIconMode = .swap) {
        settle(after: outcome, next: next)
        guard case let .success(attempted, succeeded) = outcome,
              attempted > 0, succeeded == attempted, !reduceMotion() else {
            onSettled?()
            return
        }
        let token = generation
        playback = Task { @MainActor [weak self] in
            let start = ContinuousClock.now
            for index in 0...12 {
                guard let self, !Task.isCancelled, generation == token else { return }
                guard !reduceMotion() else { show(next); onSettled?(); return }
                display(mode.rawValue + String(format: "Motion%02d", index))
                if index < 12 {
                    do { try await waitUntil(start.advanced(by: mode.duration * (index + 1) / 12)) }
                    catch { return }
                }
            }
            guard let self, generation == token else { return }
            show(next)
            onSettled?()
        }
    }

    func accessibilityOptionsChanged() {
        if reduceMotion() {
            show(settledMode, available: available)
            onSettled?()
        }
    }

    private func display(_ name: String) {
        assetName = name
        setImage(name)
    }
}

/// NotificationCenter removal is thread-safe. The immutable token wrapper
/// releases observation even when the presenter's final release is off-actor.
private final class AccessibilityOptionsObservation: @unchecked Sendable {
    let center: NotificationCenter
    let token: NSObjectProtocol
    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }
    deinit { center.removeObserver(token) }
}
