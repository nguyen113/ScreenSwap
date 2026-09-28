import CoreGraphics
import Foundation
import ScreenSwapCore
import Testing
@testable import ScreenSwapMac

@MainActor
private final class FakeAccessibilityClient: AccessibilityClient {
    var appValues: [AccessibilityApplication] = []
    var applicationsCallCount = 0
    var visibleWindowValues: [VisibleWindowSnapshot]?
    var visibleWindowsCallCount = 0
    var failingVisibleWindowEnumeration = false
    var handlesByPID: [Int32: [AccessibilityWindowHandle]] = [:]
    var attributesByToken: [String: AccessibilityWindowAttributes] = [:]
    var failingWindowEnumeration: Set<Int32> = []
    var failingAttributeReads: Set<String> = []
    var failingSizeWrites = false
    var ignoresSizeWritesUntilZoom = false
    var sizeWriteHeightAdjustment: CGFloat = 0
    var failingPositionWrites = false
    var failingZoomActions = false
    var failingFullScreenActions = false
    var failingFullScreenTokens: Set<String> = []
    var deferGeometryUpdates = false
    var transitionDelayTicks = 0
    var neverCompletesZoomExit = false
    var neverCompletesFullScreenExit = false
    var zoomGeometrySequences: [String: [CGRect]] = [:]
    private var pendingZoomStates: [String: (Bool, Int)] = [:]
    private var pendingFullScreenStates: [String: (Bool, Int)] = [:]
    var writeEvents: [String] = []
    var beginCaptureCount = 0

    func beginCapture() {
        beginCaptureCount += 1
    }

    func applications() throws -> [AccessibilityApplication] {
        applicationsCallCount += 1
        return appValues
    }

    func visibleWindows() throws -> [VisibleWindowSnapshot] {
        visibleWindowsCallCount += 1
        if failingVisibleWindowEnumeration {
            throw AccessibilityClientError.attributeReadFailed
        }
        if let visibleWindowValues {
            return visibleWindowValues
        }
        return appValues.flatMap { application in
            (handlesByPID[application.processIdentifier] ?? []).compactMap { handle in
                guard let attributes = attributesByToken[handle.token] else { return nil }
                return VisibleWindowSnapshot(
                    processIdentifier: application.processIdentifier,
                    frame: CGRect(origin: attributes.position, size: attributes.size)
                )
            }
        }
    }

    func windows(for application: AccessibilityApplication) throws -> [AccessibilityWindowHandle] {
        if failingWindowEnumeration.contains(application.processIdentifier) {
            throw AccessibilityClientError.attributeReadFailed
        }
        return handlesByPID[application.processIdentifier] ?? []
    }

    func attributes(for window: AccessibilityWindowHandle) throws -> AccessibilityWindowAttributes {
        if failingAttributeReads.contains(window.token) {
            throw AccessibilityClientError.attributeReadFailed
        }
        guard let attributes = attributesByToken[window.token] else {
            throw AccessibilityClientError.attributeReadFailed
        }
        return attributes
    }

    func advanceTransitions() {
        for token in Array(pendingZoomStates.keys) {
            guard let pending = pendingZoomStates[token] else { continue }
            if pending.1 <= 1 {
                updatePresentation(token, zoomed: pending.0)
                pendingZoomStates.removeValue(forKey: token)
            } else {
                pendingZoomStates[token] = (pending.0, pending.1 - 1)
            }
        }
        for token in Array(pendingFullScreenStates.keys) {
            guard let pending = pendingFullScreenStates[token] else { continue }
            if pending.1 <= 1 {
                updatePresentation(token, fullScreen: pending.0)
                pendingFullScreenStates.removeValue(forKey: token)
            } else {
                pendingFullScreenStates[token] = (pending.0, pending.1 - 1)
            }
        }
    }

    func setSize(_ size: CGSize, for window: AccessibilityWindowHandle) throws {
        writeEvents.append("size:\(window.token):\(size.width)x\(size.height)")
        if failingSizeWrites { throw AccessibilityClientError.writeFailed }
        if ignoresSizeWritesUntilZoom { return }
        if !deferGeometryUpdates {
            updateGeometry(
                window.token,
                size: CGSize(width: size.width, height: max(1, size.height + sizeWriteHeightAdjustment))
            )
        }
    }

    func setPosition(_ position: CGPoint, for window: AccessibilityWindowHandle) throws {
        writeEvents.append("position:\(window.token):\(position.x),\(position.y)")
        if failingPositionWrites { throw AccessibilityClientError.writeFailed }
        if !deferGeometryUpdates {
            updateGeometry(window.token, position: position)
        }
    }

    func raise(_ window: AccessibilityWindowHandle) throws {
        writeEvents.append("raise:\(window.token)")
    }

    func activateApplication(for window: AccessibilityWindowHandle) throws {
        writeEvents.append("activate:\(window.token)")
    }

    func pressZoom(for window: AccessibilityWindowHandle) throws {
        writeEvents.append("zoom:\(window.token)")
        if failingZoomActions { throw AccessibilityClientError.actionFailed }
        if var frames = zoomGeometrySequences[window.token], !frames.isEmpty {
            let nextFrame = frames.removeFirst()
            zoomGeometrySequences[window.token] = frames
            ignoresSizeWritesUntilZoom = false
            updateGeometry(window.token, position: nextFrame.origin, size: nextFrame.size)
            return
        }
        guard let current = attributesByToken[window.token]?.presentationState.isZoomed else { return }
        let target = !current
        if target == false && neverCompletesZoomExit { return }
        scheduleOrApplyZoom(window.token, target: target)
    }

    func pressFullScreen(for window: AccessibilityWindowHandle) throws {
        writeEvents.append("fullScreen:\(window.token)")
        if failingFullScreenActions || failingFullScreenTokens.contains(window.token) {
            throw AccessibilityClientError.actionFailed
        }
        guard let current = attributesByToken[window.token]?.presentationState.isFullScreen else { return }
        let target = !current
        if target == false && neverCompletesFullScreenExit { return }
        scheduleOrApplyFullScreen(window.token, target: target)
    }

    private func scheduleOrApplyZoom(_ token: String, target: Bool) {
        guard transitionDelayTicks > 0 else {
            updatePresentation(token, zoomed: target)
            return
        }
        pendingZoomStates[token] = (target, transitionDelayTicks)
    }

    private func scheduleOrApplyFullScreen(_ token: String, target: Bool) {
        guard transitionDelayTicks > 0 else {
            updatePresentation(token, fullScreen: target)
            return
        }
        pendingFullScreenStates[token] = (target, transitionDelayTicks)
    }

    private func updateGeometry(_ token: String, position: CGPoint? = nil, size: CGSize? = nil) {
        guard let current = attributesByToken[token] else { return }
        attributesByToken[token] = AccessibilityWindowAttributes(
            role: current.role,
            subrole: current.subrole,
            isMinimized: current.isMinimized,
            position: position ?? current.position,
            size: size ?? current.size,
            positionIsSettable: current.positionIsSettable,
            sizeIsSettable: current.sizeIsSettable,
            presentationState: current.presentationState
        )
    }

    private func updatePresentation(_ token: String, zoomed: Bool? = nil, fullScreen: Bool? = nil) {
        guard let current = attributesByToken[token] else { return }
        let state = current.presentationState
        attributesByToken[token] = AccessibilityWindowAttributes(
            role: current.role,
            subrole: current.subrole,
            isMinimized: current.isMinimized,
            position: current.position,
            size: current.size,
            positionIsSettable: current.positionIsSettable,
            sizeIsSettable: current.sizeIsSettable,
            presentationState: WindowPresentationState(
                isZoomed: zoomed ?? state.isZoomed,
                isFullScreen: fullScreen ?? state.isFullScreen,
                canToggleZoom: state.canToggleZoom,
                canToggleFullScreen: state.canToggleFullScreen
            )
        )
    }
}

@MainActor
private final class FakeTransitionWaiter: AccessibilityTransitionWaiting {
    var waitCount = 0
    var onWait: (() -> Void)?

    func wait(for interval: TimeInterval) {
        waitCount += 1
        onWait?()
    }
}

private let serviceDisplays = [
    DisplaySnapshot(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
    DisplaySnapshot(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
]

private func serviceAttributes(
    position: CGPoint = CGPoint(x: 100, y: 100),
    role: String = "AXWindow",
    subrole: String? = nil,
    minimized: Bool = false,
    movable: Bool = true,
    resizable: Bool = true,
    presentationState: WindowPresentationState = .unknown
) -> AccessibilityWindowAttributes {
    AccessibilityWindowAttributes(
        role: role,
        subrole: subrole,
        isMinimized: minimized,
        position: position,
        size: CGSize(width: 300, height: 200),
        positionIsSettable: movable,
        sizeIsSettable: resizable,
        presentationState: presentationState
    )
}

@Test
@MainActor
func accessibilityServiceSnapshotsEligibleWindowsWithoutWriting() {
    let client = FakeAccessibilityClient()
    let standard = AccessibilityWindowHandle(token: "standard")
    let fixed = AccessibilityWindowHandle(token: "fixed")
    let minimized = AccessibilityWindowHandle(token: "minimized")
    client.appValues = [
        AccessibilityApplication(processIdentifier: 999),
        AccessibilityApplication(processIdentifier: 100),
        AccessibilityApplication(processIdentifier: 101, isTerminated: true)
    ]
    client.handlesByPID[100] = [standard, fixed, minimized]
    client.attributesByToken[standard.token] = serviceAttributes()
    client.attributesByToken[fixed.token] = serviceAttributes(position: CGPoint(x: 1200, y: 100), resizable: false)
    client.attributesByToken[minimized.token] = serviceAttributes(minimized: true)

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)

    #expect(batch.windows.count == 2)
    #expect(batch.windows.map(\.isResizable) == [true, false])
    #expect(batch.failures.isEmpty)
    #expect(client.beginCaptureCount == 1)
    #expect(client.applicationsCallCount == 1)
    #expect(client.visibleWindowsCallCount == 1)
    #expect(client.writeEvents.isEmpty)
}

@Test
@MainActor
func accessibilityServiceCapturesVisibleWindowsAcrossApplicationsAndSkipsStageManagerHiddenWindows() {
    let client = FakeAccessibilityClient()
    let frontmost = AccessibilityApplication(processIdentifier: 100, bundleIdentifier: "com.apple.Notes")
    let inactiveStageManagerApp = AccessibilityApplication(processIdentifier: 200, bundleIdentifier: "com.apple.Safari")
    let visibleWindow = AccessibilityWindowHandle(token: "visible-window")
    let secondVisibleWindow = AccessibilityWindowHandle(token: "second-visible-window")
    let hiddenWindow = AccessibilityWindowHandle(token: "stage-manager-hidden-window")
    client.appValues = [frontmost, inactiveStageManagerApp]
    client.handlesByPID[frontmost.processIdentifier] = [visibleWindow]
    client.handlesByPID[inactiveStageManagerApp.processIdentifier] = [secondVisibleWindow, hiddenWindow]
    client.attributesByToken[visibleWindow.token] = serviceAttributes(position: CGPoint(x: 100, y: 100))
    client.attributesByToken[secondVisibleWindow.token] = serviceAttributes(position: CGPoint(x: 1200, y: 100))
    client.attributesByToken[hiddenWindow.token] = serviceAttributes(position: CGPoint(x: 1500, y: 100))
    client.visibleWindowValues = [
        VisibleWindowSnapshot(processIdentifier: frontmost.processIdentifier, frame: CGRect(x: 100, y: 100, width: 300, height: 200)),
        VisibleWindowSnapshot(processIdentifier: inactiveStageManagerApp.processIdentifier, frame: CGRect(x: 1200, y: 100, width: 300, height: 200))
    ]

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    #expect(batch.windows.count == 2)
    #expect(Set(batch.windows.map(\.snapshot.id.processIdentifier)) == [frontmost.processIdentifier, inactiveStageManagerApp.processIdentifier])
    #expect(batch.skipped.contains(WindowSkip(processIdentifier: inactiveStageManagerApp.processIdentifier, reason: .notVisible)))

    for captured in batch.windows {
        #expect(service.apply(move: WindowMove(
            windowID: captured.snapshot.id,
            destinationDisplayID: captured.snapshot.sourceDisplayID == 1 ? 2 : 1,
            frame: captured.snapshot.sourceDisplayID == 1
                ? CGRect(x: 1100, y: 100, width: 300, height: 200)
                : CGRect(x: 100, y: 100, width: 300, height: 200)
        ), isResizable: true) == .success)
    }
    #expect(client.writeEvents == [
        "size:visible-window:300.0x200.0",
        "position:visible-window:1100.0,100.0",
        "size:second-visible-window:300.0x200.0",
        "position:second-visible-window:100.0,100.0"
    ])
    #expect(!client.writeEvents.contains { $0.contains(hiddenWindow.token) })
}

@Test
@MainActor
func accessibilityServiceCapturesAndMovesWindowWithUnreadablePresentationState() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "unreadable-presentation")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes(
        presentationState: WindowPresentationState(
            canToggleZoom: true,
            canToggleFullScreen: true
        )
    )

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    #expect(batch.windows.count == 1)
    #expect(batch.skipped.isEmpty)

    let id = batch.windows[0].snapshot.id
    let destination = CGRect(x: 1100, y: 200, width: 400, height: 300)
    #expect(service.apply(
        move: WindowMove(windowID: id, destinationDisplayID: 2, frame: destination),
        isResizable: batch.windows[0].isResizable
    ) == .success)
    #expect(client.writeEvents == [
        "size:unreadable-presentation:400.0x300.0",
        "position:unreadable-presentation:1100.0,200.0"
    ])
}

@Test
@MainActor
func accessibilityServiceIsolatesApplicationAndWindowReadFailures() {
    let client = FakeAccessibilityClient()
    let good = AccessibilityWindowHandle(token: "good")
    let bad = AccessibilityWindowHandle(token: "bad")
    client.appValues = [
        AccessibilityApplication(processIdentifier: 100)
    ]
    client.handlesByPID[100] = [good, bad]
    client.attributesByToken[good.token] = serviceAttributes()
    client.failingAttributeReads = [bad.token]

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    #expect(batch.windows.count == 1)
    #expect(batch.failures.count == 1)
    #expect(batch.failures.map(\.kind) == [.attributes])
}

@Test
@MainActor
func accessibilityServiceDoesNothingWhenNoApplicationsAreRunning() {
    let client = FakeAccessibilityClient()
    client.appValues = []
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)

    let batch = service.captureWindows(displays: serviceDisplays)

    #expect(batch.windows.isEmpty)
    #expect(batch.failures.isEmpty)
    #expect(client.applicationsCallCount == 1)
    #expect(client.beginCaptureCount == 1)
    #expect(client.writeEvents.isEmpty)
}

@Test
@MainActor
func accessibilityServiceWritesSizeBeforePositionAndSkipsSizeForFixedWindow() {
    let client = FakeAccessibilityClient()
    let resizable = AccessibilityWindowHandle(token: "resizable")
    let fixed = AccessibilityWindowHandle(token: "fixed")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [resizable, fixed]
    client.attributesByToken[resizable.token] = serviceAttributes()
    client.attributesByToken[fixed.token] = serviceAttributes(position: CGPoint(x: 1200, y: 100), resizable: false)

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    let resizableID = batch.windows.first(where: { $0.isResizable })!.snapshot.id
    let fixedID = batch.windows.first(where: { !$0.isResizable })!.snapshot.id
    let destination = CGRect(x: 1100, y: 200, width: 500, height: 400)

    #expect(service.apply(move: WindowMove(windowID: resizableID, destinationDisplayID: 2, frame: destination), isResizable: true) == .success)
    #expect(service.apply(move: WindowMove(windowID: fixedID, destinationDisplayID: 1, frame: destination), isResizable: false) == .success)
    #expect(client.writeEvents.count == 3)
    #expect(client.writeEvents[0].hasPrefix("size:resizable"))
    #expect(client.writeEvents[1].hasPrefix("position:resizable"))
    #expect(client.writeEvents[2].hasPrefix("position:fixed"))
}

@Test
@MainActor
func accessibilityServiceDispatchesPositionWhenAXGeometryReadbackIsDelayed() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "delayed-geometry")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes()
    client.deferGeometryUpdates = true

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    let result = service.apply(
        move: WindowMove(
            windowID: batch.windows[0].snapshot.id,
            destinationDisplayID: 2,
            frame: CGRect(x: 1100, y: 100, width: 400, height: 300)
        ),
        isResizable: true
    )

    #expect(result == .success)
    #expect(client.writeEvents == [
        "size:delayed-geometry:400.0x300.0",
        "position:delayed-geometry:1100.0,100.0"
    ])
}

@Test
@MainActor
func accessibilityServiceDoesNotVerifyWindowHiddenInAnotherSpace() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "hidden-after-move")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes()

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    let move = WindowMove(
        windowID: batch.windows[0].snapshot.id,
        destinationDisplayID: 2,
        frame: CGRect(x: 1100, y: 100, width: 300, height: 200)
    )
    #expect(service.apply(move: move, isResizable: true) == .success)

    // Simulate macOS retaining the AX geometry while the window remains in an
    // inactive Space and is therefore absent from the on-screen Quartz list.
    client.visibleWindowValues = []
    #expect(service.verificationStatus(for: move, isResizable: true, tolerance: 2) == .pending)
}

@Test
@MainActor
func accessibilityServiceReportsWriteFailureAndRejectsStaleIDs() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "window")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes()
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    let id = batch.windows[0].snapshot.id
    client.failingSizeWrites = true
    let failed = service.apply(move: WindowMove(windowID: id, destinationDisplayID: 2, frame: .zero), isResizable: true)
    #expect(failed == WindowApplyResult(succeeded: false, failure: .size))

    _ = service.captureWindows(displays: serviceDisplays)
    #expect(service.apply(move: WindowMove(windowID: id, destinationDisplayID: 2, frame: .zero), isResizable: true) == WindowApplyResult(succeeded: false, failure: .staleWindow))
}

@Test
@MainActor
func accessibilityServiceRestoresZoomedWindowToDestinationVisibleFrame() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "zoomed")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes(
        presentationState: WindowPresentationState(
            isZoomed: true,
            canToggleZoom: true
        )
    )

    let displays = [
        DisplaySnapshot(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 20, width: 1000, height: 780)),
        DisplaySnapshot(id: 2, frame: CGRect(x: 1000, y: 0, width: 1200, height: 900), visibleFrame: CGRect(x: 1000, y: 40, width: 1200, height: 860))
    ]
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: displays)
    let id = batch.windows[0].snapshot.id

    #expect(service.apply(
        move: WindowMove(windowID: id, destinationDisplayID: 2, frame: CGRect(x: 1100, y: 100, width: 200, height: 100)),
        isResizable: true
    ) == .success)
    #expect(client.writeEvents == [
        "zoom:zoomed",
        "size:zoomed:1200.0x860.0",
        "position:zoomed:1000.0,40.0",
        "zoom:zoomed"
    ])
}

@Test
@MainActor
func accessibilityServicePreservesVisuallyMaximizedWindowWhenAXZoomStateIsUnavailable() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "visually-maximized")
    let sourceVisibleFrame = serviceDisplays[0].visibleFrame
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: sourceVisibleFrame.origin,
        size: sourceVisibleFrame.size,
        positionIsSettable: true,
        sizeIsSettable: true,
        presentationState: .unknown
    )

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    #expect(batch.windows.count == 1)
    #expect(batch.windows[0].presentationState.isZoomed == nil)
    #expect(batch.windows[0].isVisuallyMaximized)

    #expect(service.apply(
        move: WindowMove(
            windowID: batch.windows[0].snapshot.id,
            destinationDisplayID: 2,
            frame: CGRect(x: 1200, y: 100, width: 300, height: 200)
        ),
        isResizable: true
    ) == .success)
    #expect(client.writeEvents == [
        "size:visually-maximized:1000.0x800.0",
        "position:visually-maximized:1000.0,0.0"
    ])
    #expect(!client.writeEvents.contains { $0.hasPrefix("zoom:") })
}

@Test
@MainActor
func accessibilityServiceMapsUnknownVisualMaximizationToDestinationVisibleFrame() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "unknown-native-zoom")
    let source = serviceDisplays[0]
    let destination = serviceDisplays[1]
    let normalDestinationFrame = CGRect(x: 1_120, y: 100, width: 300, height: 200)
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: source.visibleFrame.origin,
        size: source.visibleFrame.size,
        positionIsSettable: true,
        sizeIsSettable: true,
        presentationState: WindowPresentationState(canToggleZoom: true)
    )
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    let id = batch.windows[0].snapshot.id
    #expect(batch.windows[0].isVisuallyMaximized)

    #expect(service.apply(
        move: WindowMove(windowID: id, destinationDisplayID: destination.id, frame: normalDestinationFrame),
        isResizable: true
    ) == .success)
    #expect(client.writeEvents == [
        "size:unknown-native-zoom:1000.0x800.0",
        "position:unknown-native-zoom:1000.0,0.0"
    ])
    #expect(CGRect(
        origin: client.attributesByToken[handle.token]!.position,
        size: client.attributesByToken[handle.token]!.size
    ) == destination.visibleFrame)
}

@Test
@MainActor
func accessibilityServiceMovesBeforeGrowingWindowedMaximizationOntoLargerDisplay() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "windowed-zoom-recovery")
    let source = DisplaySnapshot(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 600, height: 400),
        visibleFrame: CGRect(x: 0, y: 0, width: 600, height: 400)
    )
    let destination = DisplaySnapshot(
        id: 2,
        frame: CGRect(x: 600, y: 0, width: 1_000, height: 800),
        visibleFrame: CGRect(x: 600, y: 0, width: 1_000, height: 800)
    )
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: source.visibleFrame.origin,
        size: source.visibleFrame.size,
        positionIsSettable: true,
        sizeIsSettable: true,
        presentationState: WindowPresentationState(canToggleZoom: true)
    )
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: [source, destination])

    #expect(service.apply(
        move: WindowMove(
            windowID: batch.windows[0].snapshot.id,
            destinationDisplayID: destination.id,
            frame: CGRect(x: 700, y: 40, width: 300, height: 200)
        ),
        isResizable: true
    ) == .success)
    #expect(client.writeEvents == [
        "position:windowed-zoom-recovery:600.0,0.0",
        "size:windowed-zoom-recovery:1000.0x800.0",
        "position:windowed-zoom-recovery:600.0,0.0"
    ])
    #expect(CGRect(
        origin: client.attributesByToken[handle.token]!.position,
        size: client.attributesByToken[handle.token]!.size
    ) == destination.visibleFrame)
}

@Test
@MainActor
func accessibilityServiceAcceptsWindowedMaximizationWithDecoratedFrameInset() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "decorated-windowed-max")
    let source = DisplaySnapshot(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
    )
    let destination = DisplaySnapshot(
        id: 2,
        frame: CGRect(x: 1_000, y: 0, width: 600, height: 400),
        visibleFrame: CGRect(x: 1_000, y: 0, width: 600, height: 400)
    )
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: source.visibleFrame.origin,
        size: source.visibleFrame.size,
        positionIsSettable: true,
        sizeIsSettable: true
    )
    client.sizeWriteHeightAdjustment = -7

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: [source, destination])

    #expect(service.apply(
        move: WindowMove(
            windowID: batch.windows[0].snapshot.id,
            destinationDisplayID: destination.id,
            frame: .zero
        ),
        isResizable: true
    ) == .success)
}

@Test
@MainActor
func accessibilityServicePreservesVisuallyMaximizedWindowFromSecondDisplay() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "second-display-maximized")
    let sourceVisibleFrame = serviceDisplays[1].visibleFrame
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: sourceVisibleFrame.origin,
        size: sourceVisibleFrame.size,
        positionIsSettable: true,
        sizeIsSettable: true
    )

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    #expect(batch.windows[0].isVisuallyMaximized)

    #expect(service.apply(
        move: WindowMove(
            windowID: batch.windows[0].snapshot.id,
            destinationDisplayID: 1,
            frame: CGRect(x: 100, y: 100, width: 300, height: 200)
        ),
        isResizable: true
    ) == .success)
    #expect(client.writeEvents == [
        "size:second-display-maximized:1000.0x800.0",
        "position:second-display-maximized:0.0,0.0"
    ])
}

@Test
@MainActor
func accessibilityServiceNormalizesOnePointMaximizedEdgeDriftBeforePlanning() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "maximized-edge-drift")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: CGPoint(x: 999, y: 0),
        size: CGSize(width: 1_001, height: 800),
        positionIsSettable: true,
        sizeIsSettable: true
    )

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)

    #expect(batch.windows.count == 1)
    #expect(batch.windows[0].snapshot.sourceDisplayID == 2)
    #expect(batch.windows[0].isVisuallyMaximized)
    #expect(batch.windows[0].snapshot.frame == serviceDisplays[1].visibleFrame)
    #expect(WindowMappingEngine().makeSwapMoves(
        windows: batch.windows.map(\.snapshot),
        displayA: serviceDisplays[0],
        displayB: serviceDisplays[1]
    ).count == 1)
}

@Test
@MainActor
func accessibilityServicePreservesNearVisibleFrameAcrossUnequalDisplays() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "scaled-maximized")
    let displayA = DisplaySnapshot(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 2000, height: 1200),
        visibleFrame: CGRect(x: 0, y: 40, width: 2000, height: 1160)
    )
    let displayB = DisplaySnapshot(
        id: 2,
        frame: CGRect(x: 2000, y: 0, width: 1280, height: 800),
        visibleFrame: CGRect(x: 2000, y: 0, width: 1280, height: 800)
    )
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: CGPoint(x: 30, y: 60),
        size: CGSize(width: 1_940, height: 1_120),
        positionIsSettable: true,
        sizeIsSettable: true
    )

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: [displayA, displayB])
    #expect(batch.windows[0].isVisuallyMaximized)

    #expect(service.apply(
        move: WindowMove(
            windowID: batch.windows[0].snapshot.id,
            destinationDisplayID: displayB.id,
            frame: CGRect(x: 2020, y: 20, width: 1_000, height: 600)
        ),
        isResizable: true
    ) == .success)
    #expect(client.writeEvents == [
        "size:scaled-maximized:1280.0x800.0",
        "position:scaled-maximized:2000.0,0.0"
    ])
}

@Test
@MainActor
func accessibilityServiceRoundTripsVisualMaximizationBetweenDockedAndUndockedDisplays() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "dock-round-trip")
    let mainDisplay = DisplaySnapshot(
        id: 3,
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 968)
    )
    let secondDisplay = DisplaySnapshot(
        id: 1,
        frame: CGRect(x: 1920, y: 267, width: 1280, height: 800),
        visibleFrame: CGRect(x: 1920, y: 267, width: 1280, height: 800)
    )
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: mainDisplay.visibleFrame.origin,
        size: mainDisplay.visibleFrame.size,
        positionIsSettable: true,
        sizeIsSettable: true
    )

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let firstBatch = service.captureWindows(displays: [secondDisplay, mainDisplay])
    #expect(firstBatch.windows[0].isVisuallyMaximized)
    #expect(service.apply(
        move: WindowMove(
            windowID: firstBatch.windows[0].snapshot.id,
            destinationDisplayID: secondDisplay.id,
            frame: .zero
        ),
        isResizable: true
    ) == .success)
    #expect(CGRect(
        origin: client.attributesByToken[handle.token]!.position,
        size: client.attributesByToken[handle.token]!.size
    ) == secondDisplay.visibleFrame)

    let secondBatch = service.captureWindows(displays: [secondDisplay, mainDisplay])
    #expect(secondBatch.windows[0].isVisuallyMaximized)
    #expect(service.apply(
        move: WindowMove(
            windowID: secondBatch.windows[0].snapshot.id,
            destinationDisplayID: mainDisplay.id,
            frame: .zero
        ),
        isResizable: true
    ) == .success)
    #expect(CGRect(
        origin: client.attributesByToken[handle.token]!.position,
        size: client.attributesByToken[handle.token]!.size
    ) == mainDisplay.visibleFrame)
}

@Test
@MainActor
func accessibilityServiceRetainsMaximizedIntentWhenUnequalDisplayGeometryChangesOnReturn() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "retained-maximized-intent")
    let mainDisplay = DisplaySnapshot(
        id: 3,
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 968)
    )
    let secondDisplay = DisplaySnapshot(
        id: 1,
        frame: CGRect(x: 1920, y: 267, width: 1280, height: 800),
        visibleFrame: CGRect(x: 1920, y: 267, width: 1280, height: 800)
    )
    let processIdentifier: Int32 = 100
    let windowNumber: UInt32 = 42
    client.appValues = [AccessibilityApplication(processIdentifier: processIdentifier)]
    client.handlesByPID[processIdentifier] = [handle]
    client.attributesByToken[handle.token] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: mainDisplay.visibleFrame.origin,
        size: mainDisplay.visibleFrame.size,
        positionIsSettable: true,
        sizeIsSettable: true
    )
    client.visibleWindowValues = [VisibleWindowSnapshot(
        processIdentifier: processIdentifier,
        frame: mainDisplay.visibleFrame,
        windowNumber: windowNumber
    )]

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let firstBatch = service.captureWindows(displays: [secondDisplay, mainDisplay])
    #expect(firstBatch.windows[0].isVisuallyMaximized)
    #expect(service.apply(
        move: WindowMove(windowID: firstBatch.windows[0].snapshot.id, destinationDisplayID: secondDisplay.id, frame: .zero),
        isResizable: true
    ) == .success)

    // Model an application that has adjusted the first destination frame
    // enough that geometry alone would no longer identify it as maximized.
    let adjustedSecondFrame = CGRect(x: 1_960, y: 285, width: 1_180, height: 740)
    client.attributesByToken[handle.token] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: adjustedSecondFrame.origin,
        size: adjustedSecondFrame.size,
        positionIsSettable: true,
        sizeIsSettable: true
    )
    client.visibleWindowValues = [VisibleWindowSnapshot(
        processIdentifier: processIdentifier,
        frame: adjustedSecondFrame,
        windowNumber: windowNumber
    )]

    let secondBatch = service.captureWindows(displays: [secondDisplay, mainDisplay])
    #expect(secondBatch.windows[0].isVisuallyMaximized)
    #expect(service.apply(
        move: WindowMove(windowID: secondBatch.windows[0].snapshot.id, destinationDisplayID: mainDisplay.id, frame: .zero),
        isResizable: true
    ) == .success)
    #expect(CGRect(
        origin: client.attributesByToken[handle.token]!.position,
        size: client.attributesByToken[handle.token]!.size
    ) == mainDisplay.visibleFrame)
}

@Test
@MainActor
func accessibilityServiceCapturesAXConfirmedFullScreenWindowWhenQuartzOmitsItsSpace() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "full-screen-not-in-quartz")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.visibleWindowValues = []
    client.attributesByToken[handle.token] = serviceAttributes(
        presentationState: WindowPresentationState(
            isFullScreen: true,
            canToggleFullScreen: true
        )
    )

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)

    #expect(batch.windows.count == 1)
    #expect(batch.windows[0].presentationState.isFullScreen == true)
    #expect(!batch.skipped.contains { $0.reason == .notVisible })
}

@Test
@MainActor
func accessibilityServiceRestoresFullScreenStateAfterRelocatingWindow() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "full-screen")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes(
        presentationState: WindowPresentationState(
            isFullScreen: true,
            canToggleFullScreen: true
        )
    )

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    let id = batch.windows[0].snapshot.id
    #expect(service.apply(
        move: WindowMove(windowID: id, destinationDisplayID: 2, frame: CGRect(x: 1100, y: 200, width: 500, height: 400)),
        isResizable: true
    ) == .success)
    #expect(client.writeEvents == [
        "activate:full-screen",
        "fullScreen:full-screen",
        "size:full-screen:1000.0x800.0",
        "position:full-screen:1000.0,0.0",
        "fullScreen:full-screen"
    ])
}

@Test
@MainActor
func accessibilityServiceCapturesAndMovesNativeFullScreenWindowWithTemporarilyLockedGeometry() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "native-full-screen-locked-geometry")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes(
        movable: false,
        resizable: false,
        presentationState: WindowPresentationState(
            isFullScreen: true,
            canToggleFullScreen: true
        )
    )
    // Quartz does not list a window in a different full-screen Space.
    client.visibleWindowValues = []

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)

    #expect(batch.windows.count == 1)
    #expect(batch.windows[0].isResizable == false)
    #expect(batch.skipped.isEmpty)

    #expect(service.apply(
        move: WindowMove(
            windowID: batch.windows[0].snapshot.id,
            destinationDisplayID: 2,
            frame: CGRect(x: 1100, y: 200, width: 400, height: 300)
        ),
        isResizable: false
    ) == .success)
    #expect(client.writeEvents == [
        "activate:native-full-screen-locked-geometry",
        "fullScreen:native-full-screen-locked-geometry",
        "size:native-full-screen-locked-geometry:1000.0x800.0",
        "position:native-full-screen-locked-geometry:1000.0,0.0",
        "fullScreen:native-full-screen-locked-geometry"
    ])
}

@Test
@MainActor
func accessibilityServiceRoundTripsMixedNativeAndWindowedFullScreenModes() {
    let client = FakeAccessibilityClient()
    let nativeFullScreen = AccessibilityWindowHandle(token: "native-full-screen")
    let windowedFullScreen = AccessibilityWindowHandle(token: "windowed-full-screen")
    let mainDisplay = DisplaySnapshot(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
        visibleFrame: CGRect(x: 0, y: 30, width: 1_000, height: 770)
    )
    let secondDisplay = DisplaySnapshot(
        id: 2,
        frame: CGRect(x: 1_000, y: 200, width: 600, height: 400),
        visibleFrame: CGRect(x: 1_000, y: 200, width: 600, height: 400)
    )
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [nativeFullScreen, windowedFullScreen]
    client.attributesByToken[nativeFullScreen.token] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: mainDisplay.frame.origin,
        size: mainDisplay.frame.size,
        positionIsSettable: true,
        sizeIsSettable: true,
        presentationState: WindowPresentationState(
            isFullScreen: true,
            canToggleFullScreen: true
        )
    )
    client.attributesByToken[windowedFullScreen.token] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: secondDisplay.visibleFrame.origin,
        size: secondDisplay.visibleFrame.size,
        positionIsSettable: true,
        sizeIsSettable: true
    )

    let displays = [mainDisplay, secondDisplay]
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let mapping = WindowMappingEngine()
    func swapOnce() {
        let batch = service.captureWindows(displays: displays)
        let moves = mapping.makeSwapMoves(
            windows: batch.windows.map(\.snapshot),
            displayA: mainDisplay,
            displayB: secondDisplay
        )
        #expect(moves.count == 2)
        for move in moves {
            let captured = batch.windows.first { $0.snapshot.id == move.windowID }!
            #expect(service.apply(move: move, isResizable: captured.isResizable) == .success)
        }
    }

    swapOnce()
    #expect(client.attributesByToken[nativeFullScreen.token]!.presentationState.isFullScreen == true)
    #expect(CGRect(
        origin: client.attributesByToken[nativeFullScreen.token]!.position,
        size: client.attributesByToken[nativeFullScreen.token]!.size
    ) == secondDisplay.frame)
    #expect(client.attributesByToken[windowedFullScreen.token]!.presentationState.isFullScreen != true)
    #expect(CGRect(
        origin: client.attributesByToken[windowedFullScreen.token]!.position,
        size: client.attributesByToken[windowedFullScreen.token]!.size
    ) == mainDisplay.visibleFrame)

    swapOnce()
    #expect(client.attributesByToken[nativeFullScreen.token]!.presentationState.isFullScreen == true)
    #expect(CGRect(
        origin: client.attributesByToken[nativeFullScreen.token]!.position,
        size: client.attributesByToken[nativeFullScreen.token]!.size
    ) == mainDisplay.frame)
    #expect(client.attributesByToken[windowedFullScreen.token]!.presentationState.isFullScreen != true)
    #expect(CGRect(
        origin: client.attributesByToken[windowedFullScreen.token]!.position,
        size: client.attributesByToken[windowedFullScreen.token]!.size
    ) == secondDisplay.visibleFrame)
}

@Test
@MainActor
func accessibilityServiceDoesNotInferPresentationStateFromBoundsAndContinuesAfterActionFailure() {
    let client = FakeAccessibilityClient()
    let unsupported = AccessibilityWindowHandle(token: "unsupported")
    let ordinary = AccessibilityWindowHandle(token: "ordinary")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [unsupported, ordinary]
    client.attributesByToken[unsupported.token] = serviceAttributes(
        position: CGPoint(x: 0, y: 0),
        presentationState: WindowPresentationState(
            isFullScreen: true,
            canToggleFullScreen: true
        )
    )
    client.attributesByToken[ordinary.token] = serviceAttributes(position: CGPoint(x: 1200, y: 100))
    client.failingFullScreenTokens = [unsupported.token]

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    let unsupportedID = batch.windows.first { $0.presentationState.isFullScreen == true }!.snapshot.id
    let ordinaryID = batch.windows.first { $0.presentationState == .unknown }!.snapshot.id

    #expect(service.apply(
        move: WindowMove(windowID: unsupportedID, destinationDisplayID: 2, frame: CGRect(x: 1100, y: 100, width: 300, height: 200)),
        isResizable: true
    ) == WindowApplyResult(succeeded: false, failure: .fullScreen))
    #expect(service.apply(
        move: WindowMove(windowID: ordinaryID, destinationDisplayID: 1, frame: CGRect(x: 100, y: 100, width: 300, height: 200)),
        isResizable: true
    ) == .success)
    #expect(client.writeEvents == [
        "activate:unsupported",
        "fullScreen:unsupported",
        "size:ordinary:300.0x200.0",
        "position:ordinary:100.0,100.0"
    ])
}

@Test
@MainActor
func accessibilityServiceRoundTripsDelayedZoomAndFullScreenWindows() {
    let client = FakeAccessibilityClient()
    let zoomed = AccessibilityWindowHandle(token: "zoomed-round-trip")
    let fullScreen = AccessibilityWindowHandle(token: "full-screen-round-trip")
    let initialFrame = serviceDisplays[0].visibleFrame
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [zoomed, fullScreen]
    client.attributesByToken[zoomed.token] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: initialFrame.origin,
        size: initialFrame.size,
        positionIsSettable: true,
        sizeIsSettable: true,
        presentationState: WindowPresentationState(isZoomed: true, canToggleZoom: true)
    )
    client.attributesByToken[fullScreen.token] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: initialFrame.origin,
        size: initialFrame.size,
        positionIsSettable: true,
        sizeIsSettable: true,
        presentationState: WindowPresentationState(isFullScreen: true, canToggleFullScreen: true)
    )
    client.transitionDelayTicks = 2
    let waiter = FakeTransitionWaiter()
    waiter.onWait = { client.advanceTransitions() }
    let service = AccessibilityWindowService(
        client: client,
        processIdentifier: 999,
        transitionPolicy: PresentationTransitionPolicy(timeout: 0.1, pollInterval: 0.001),
        transitionWaiter: waiter
    )
    let engine = WindowMappingEngine()

    let firstBatch = service.captureWindows(displays: serviceDisplays)
    let firstMoves = engine.makeSwapMoves(
        windows: firstBatch.windows.map(\.snapshot),
        displayA: serviceDisplays[0],
        displayB: serviceDisplays[1]
    )
    for move in firstMoves {
        let capability = firstBatch.windows.first { $0.snapshot.id == move.windowID }!.isResizable
        #expect(service.apply(move: move, isResizable: capability) == .success)
    }

    let secondBatch = service.captureWindows(displays: serviceDisplays)
    let secondMoves = engine.makeSwapMoves(
        windows: secondBatch.windows.map(\.snapshot),
        displayA: serviceDisplays[0],
        displayB: serviceDisplays[1]
    )
    for move in secondMoves {
        let capability = secondBatch.windows.first { $0.snapshot.id == move.windowID }!.isResizable
        #expect(service.apply(move: move, isResizable: capability) == .success)
    }

    #expect(client.attributesByToken[zoomed.token]!.position == initialFrame.origin)
    #expect(client.attributesByToken[zoomed.token]!.size == initialFrame.size)
    #expect(client.attributesByToken[zoomed.token]!.presentationState.isZoomed == true)
    #expect(client.attributesByToken[fullScreen.token]!.position == initialFrame.origin)
    #expect(client.attributesByToken[fullScreen.token]!.size == initialFrame.size)
    #expect(client.attributesByToken[fullScreen.token]!.presentationState.isFullScreen == true)
    #expect(waiter.waitCount > 0)
}

@Test
@MainActor
func accessibilityServiceLeavesPresentationWindowUntouchedWhenTransitionDoesNotComplete() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "stuck-zoom")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    let original = serviceAttributes(
        presentationState: WindowPresentationState(isZoomed: true, canToggleZoom: true)
    )
    client.attributesByToken[handle.token] = original
    client.neverCompletesZoomExit = true
    let waiter = FakeTransitionWaiter()
    waiter.onWait = { client.advanceTransitions() }
    let service = AccessibilityWindowService(
        client: client,
        processIdentifier: 999,
        transitionPolicy: PresentationTransitionPolicy(timeout: 0.005, pollInterval: 0.001),
        transitionWaiter: waiter
    )
    let batch = service.captureWindows(displays: serviceDisplays)
    let id = batch.windows[0].snapshot.id

    #expect(service.apply(
        move: WindowMove(windowID: id, destinationDisplayID: 2, frame: CGRect(x: 1100, y: 100, width: 300, height: 200)),
        isResizable: true
    ) == WindowApplyResult(succeeded: false, failure: .zoom))
    #expect(client.attributesByToken[handle.token] == original)
    #expect(client.writeEvents == ["zoom:stuck-zoom"])
    #expect(waiter.waitCount > 0)
}

@Test
@MainActor
func accessibilityServiceExcludesAuxiliaryWidgetWindowsFromCaptureAndWrites() {
    let client = FakeAccessibilityClient()
    let standard = AccessibilityWindowHandle(token: "standard-window")
    let widget = AccessibilityWindowHandle(token: "desktop-widget")
    let hostedWidget = AccessibilityWindowHandle(token: "hosted-widget")
    client.appValues = [
        AccessibilityApplication(processIdentifier: 100),
        AccessibilityApplication(processIdentifier: 101, bundleIdentifier: "com.apple.notificationcenterui")
    ]
    client.handlesByPID[100] = [standard, widget]
    client.handlesByPID[101] = [hostedWidget]
    client.attributesByToken[standard.token] = serviceAttributes()
    client.attributesByToken[widget.token] = serviceAttributes(subrole: "AXSystemFloatingWindow")

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)

    #expect(batch.windows.count == 1)
    #expect(batch.skipped.contains(WindowSkip(processIdentifier: 100, reason: .auxiliary)))
    #expect(batch.skipped.contains(WindowSkip(processIdentifier: 101, reason: .auxiliary)))
    #expect(client.applicationsCallCount == 1)
    #expect(client.writeEvents.isEmpty)
}

@Test
@MainActor
func accessibilityServiceDoesNotCaptureOrWriteWhenOnScreenWindowListCannotBeRead() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "visible-list-failure")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes()
    client.failingVisibleWindowEnumeration = true

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)

    #expect(batch.windows.isEmpty)
    #expect(batch.failures.map(\.kind) == [.visibleWindowEnumeration])
    #expect(client.writeEvents.isEmpty)
}
