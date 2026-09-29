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
    var frameReadCount = 0
    var attributesReadCount = 0
    var windowNumbersByToken: [String: UInt32] = [:]
    var hiddenTokens: Set<String> = []
    var failingVisibleWindowEnumeration = false
    var handlesByPID: [Int32: [AccessibilityWindowHandle]] = [:]
    var attributesByToken: [String: AccessibilityWindowAttributes] = [:]
    var failingWindowEnumeration: Set<Int32> = []
    var failingAttributeReads: Set<String> = []
    var titlesByToken: [String: String?] = [:]
    var failingTitleReads: Set<String> = []
    var failingSizeWrites = false
    var enhancedUIEnabled = false
    var assistiveTechnologyActive = false
    /// Simulates macOS rejecting a resize that exceeds the current display's
    /// available size while the window center is still on that display.
    var sizeLimitAtCurrentCenter: (frame: CGRect, maximumSize: CGSize)?
    var ignoresSizeWritesUntilZoom = false
    var sizeWriteHeightAdjustment: CGFloat = 0
    var failingPositionWrites = false
    var failingRaiseActions = false
    var hidesOnDestinationTokens: Set<String> = []
    var hideAnotherOnRaise: String?
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
                guard !hiddenTokens.contains(handle.token), let attributes = attributesByToken[handle.token] else { return nil }
                return VisibleWindowSnapshot(
                    processIdentifier: application.processIdentifier,
                    frame: CGRect(origin: attributes.position, size: attributes.size),
                    windowNumber: windowNumbersByToken[handle.token]
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
        attributesReadCount += 1
        if failingAttributeReads.contains(window.token) {
            throw AccessibilityClientError.attributeReadFailed
        }
        guard let attributes = attributesByToken[window.token] else {
            throw AccessibilityClientError.attributeReadFailed
        }
        return attributes
    }

    func frame(for window: AccessibilityWindowHandle) throws -> CGRect {
        frameReadCount += 1
        guard let value = attributesByToken[window.token] else {
            throw AccessibilityClientError.attributeReadFailed
        }
        return CGRect(origin: value.position, size: value.size)
    }

    func title(for window: AccessibilityWindowHandle) throws -> String? {
        if failingTitleReads.contains(window.token) {
            throw AccessibilityClientError.attributeReadFailed
        }
        return titlesByToken[window.token] ?? nil
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

    func withGeometryUpdates(for window: AccessibilityWindowHandle, _ updates: () -> WindowApplyResult) -> WindowApplyResult {
        AccessibilityGeometryUpdateScope.perform(
            assistiveTechnologyActive: assistiveTechnologyActive,
            readEnhancedUI: { self.enhancedUIEnabled },
            writeEnhancedUI: { self.enhancedUIEnabled = $0; return true },
            updates: updates
        )
    }

    func setSize(_ size: CGSize, for window: AccessibilityWindowHandle) throws {
        writeEvents.append("size:\(window.token):\(size.width)x\(size.height)")
        if failingSizeWrites { throw AccessibilityClientError.writeFailed }
        if ignoresSizeWritesUntilZoom || enhancedUIEnabled { return }
        if let limit = sizeLimitAtCurrentCenter,
           let current = attributesByToken[window.token],
           limit.frame.contains(CGPoint(
                x: current.position.x + current.size.width / 2,
                y: current.position.y + current.size.height / 2
           )),
           (size.width > limit.maximumSize.width || size.height > limit.maximumSize.height) {
            return
        }
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
            if hidesOnDestinationTokens.contains(window.token), position.x >= 1000 {
                hiddenTokens.insert(window.token)
            }
        }
    }

    func raise(_ window: AccessibilityWindowHandle) throws {
        writeEvents.append("raise:\(window.token)")
        if failingRaiseActions { throw AccessibilityClientError.actionFailed }
        hiddenTokens.remove(window.token)
        if let hideAnotherOnRaise { hiddenTokens.insert(hideAnotherOnRaise) }
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
    size: CGSize = CGSize(width: 300, height: 200),
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
        size: size,
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
func unreadableWindowTitleDoesNotAffectSwapCaptureAndUsesInventoryFallback() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "title-unreadable")
    let application = AccessibilityApplication(processIdentifier: 100, localizedName: "Finder")
    client.appValues = [application]
    client.handlesByPID[application.processIdentifier] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes()
    client.failingTitleReads.insert(handle.token)
    client.visibleWindowValues = [
        VisibleWindowSnapshot(
            processIdentifier: application.processIdentifier,
            frame: CGRect(x: 100, y: 100, width: 300, height: 200),
            windowNumber: 42
        )
    ]
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)

    let batch = service.captureWindows(displays: serviceDisplays)
    #expect(batch.windows.count == 1)
    #expect(batch.failures.isEmpty)

    let inventory = service.inventory(displays: serviceDisplays.enumerated().map {
        InventoryDisplay(snapshot: $0.element, ordinal: $0.offset + 1, name: nil)
    })
    #expect(inventory.windows.map(\.label) == ["Finder — Window 1"])
    #expect(inventory.windows.first?.isSelectable == true)
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
func accessibilityServiceClampsFixedWindowUsingCapturedSize() {
    let client = FakeAccessibilityClient()
    let fixed = AccessibilityWindowHandle(token: "fixed-near-edge")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [fixed]
    client.attributesByToken[fixed.token] = serviceAttributes(
        position: CGPoint(x: 100, y: 100),
        size: CGSize(width: 600, height: 400),
        resizable: false
    )

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    let move = WindowMove(
        windowID: batch.windows[0].snapshot.id,
        destinationDisplayID: 2,
        // The planner's scaled frame fits at this origin, but the real fixed
        // window does not. AX must receive an origin clamped for 600x400.
        frame: CGRect(x: 1_750, y: 750, width: 300, height: 200)
    )

    #expect(service.apply(move: move, isResizable: false) == .success)
    #expect(client.writeEvents == ["position:fixed-near-edge:1400.0,400.0"])
    #expect(service.verificationStatus(for: move, isResizable: false, tolerance: 2) == .verified)
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
    #expect(service.verificationStatus(for: move, isResizable: true, tolerance: 2) == .notVisible)
}

@Test
@MainActor
func accessibilityServiceRestoresCapturedFrameAfterSpaceVisibilityFailure() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "restore-after-space-failure")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes(
        position: CGPoint(x: 100, y: 120),
        size: CGSize(width: 320, height: 240)
    )

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    let id = batch.windows[0].snapshot.id
    let move = WindowMove(
        windowID: id,
        destinationDisplayID: 2,
        frame: CGRect(x: 1_250, y: 200, width: 400, height: 300)
    )
    #expect(service.apply(move: move, isResizable: true) == .success)

    client.visibleWindowValues = []
    #expect(service.verificationStatus(for: move, isResizable: true, tolerance: 2) == .notVisible)
    #expect(service.restore(windowID: id, isResizable: true) == .success)
    #expect(client.writeEvents.suffix(2) == [
        "size:restore-after-space-failure:320.0x240.0",
        "position:restore-after-space-failure:100.0,120.0"
    ])
    let restored = try? client.attributes(for: handle)
    #expect(restored?.position == CGPoint(x: 100, y: 120))
    #expect(restored?.size == CGSize(width: 320, height: 240))
}

@Test
@MainActor
func accessibilityServiceRestoresLargeFrameByReturningToSourceBeforeResize() {
    let source = DisplaySnapshot(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_000)
    )
    let destination = DisplaySnapshot(
        id: 2,
        frame: CGRect(x: 1_920, y: 0, width: 1_280, height: 800),
        visibleFrame: CGRect(x: 1_920, y: 0, width: 1_280, height: 800)
    )
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "large-rollback")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes(
        position: CGPoint(x: 100, y: 50),
        size: CGSize(width: 1_600, height: 900)
    )
    client.sizeLimitAtCurrentCenter = (
        frame: destination.visibleFrame,
        maximumSize: CGSize(width: 1_280, height: 800)
    )

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: [source, destination])
    let id = batch.windows[0].snapshot.id
    let failedMove = WindowMove(
        windowID: id,
        destinationDisplayID: destination.id,
        frame: CGRect(x: 2_020, y: 40, width: 1_066, height: 720)
    )
    #expect(service.apply(move: failedMove, isResizable: true) == .success)
    #expect(service.restore(windowID: id, isResizable: true) == .success)
    #expect(client.writeEvents.suffix(3) == [
        "position:large-rollback:100.0,50.0",
        "size:large-rollback:1600.0x900.0",
        "position:large-rollback:100.0,50.0"
    ])
    let restored = try? client.attributes(for: handle)
    #expect(restored?.position == CGPoint(x: 100, y: 50))
    #expect(restored?.size == CGSize(width: 1_600, height: 900))
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
        position: CGPoint(x: 0, y: 20), size: CGSize(width: 1000, height: 780),
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
func accessibilityServiceSkipsAXConfirmedFullScreenWindowWhenQuartzOmitsItsSpace() {
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

    #expect(batch.windows.isEmpty)
    #expect(batch.skipped.contains(WindowSkip(processIdentifier: 100, reason: .nativeFullScreenSpace)))
    #expect(client.writeEvents.isEmpty)
}

@Test
@MainActor
func accessibilityServiceReservesNativeFullScreenQuartzIdentityBeforeSkippingIt() {
    let client = FakeAccessibilityClient()
    let application = AccessibilityApplication(processIdentifier: 100)
    let nativeFullScreen = AccessibilityWindowHandle(token: "native-full-screen")
    let hiddenOrdinary = AccessibilityWindowHandle(token: "hidden-ordinary")
    let sharedFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    client.appValues = [application]
    client.handlesByPID[application.processIdentifier] = [nativeFullScreen, hiddenOrdinary]
    client.attributesByToken[nativeFullScreen.token] = serviceAttributes(
        position: sharedFrame.origin,
        size: sharedFrame.size,
        presentationState: WindowPresentationState(isFullScreen: true, canToggleFullScreen: true)
    )
    // AX can enumerate a window in another Space with the same geometry, but
    // Quartz exposes only the native full-screen surface in this capture.
    client.attributesByToken[hiddenOrdinary.token] = serviceAttributes(
        position: sharedFrame.origin,
        size: sharedFrame.size
    )
    client.visibleWindowValues = [VisibleWindowSnapshot(
        processIdentifier: application.processIdentifier,
        frame: sharedFrame,
        windowNumber: 41
    )]

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)

    #expect(batch.windows.isEmpty)
    #expect(batch.knownRuntimeKeys.isEmpty)
    #expect(batch.skipped.contains(WindowSkip(
        processIdentifier: application.processIdentifier,
        reason: .nativeFullScreenSpace
    )))
    #expect(batch.skipped.contains(WindowSkip(
        processIdentifier: application.processIdentifier,
        reason: .notVisible
    )))
    #expect(client.writeEvents.isEmpty)
}

@Test
@MainActor
func accessibilityServiceReservesNativeFullScreenQuartzIdentityRegardlessOfAXOrder() {
    let client = FakeAccessibilityClient()
    let application = AccessibilityApplication(processIdentifier: 100)
    let nativeFullScreen = AccessibilityWindowHandle(token: "native-full-screen")
    let hiddenOrdinary = AccessibilityWindowHandle(token: "hidden-ordinary")
    let sharedFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    client.appValues = [application]
    // The hidden ordinary window arrives first from AX, but Quartz only
    // exposes the native full-screen surface.
    client.handlesByPID[application.processIdentifier] = [hiddenOrdinary, nativeFullScreen]
    client.attributesByToken[nativeFullScreen.token] = serviceAttributes(
        position: sharedFrame.origin,
        size: sharedFrame.size,
        presentationState: WindowPresentationState(isFullScreen: true, canToggleFullScreen: true)
    )
    client.attributesByToken[hiddenOrdinary.token] = serviceAttributes(
        position: sharedFrame.origin,
        size: sharedFrame.size
    )
    client.visibleWindowValues = [VisibleWindowSnapshot(
        processIdentifier: application.processIdentifier,
        frame: sharedFrame,
        windowNumber: 41
    )]

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    let inventory = service.inventory(displays: serviceDisplays.enumerated().map {
        InventoryDisplay(snapshot: $0.element, ordinal: $0.offset + 1, name: nil)
    })

    #expect(batch.windows.isEmpty)
    #expect(batch.knownRuntimeKeys.isEmpty)
    #expect(batch.skipped.filter { $0.reason == .nativeFullScreenSpace }.count == 1)
    #expect(batch.skipped.filter { $0.reason == .notVisible }.count == 1)
    #expect(inventory.windows.count == 2)
    #expect(inventory.windows.allSatisfy { $0.key == nil && !$0.isSelectable })
    #expect(inventory.windows.filter(\.isNativeFullScreenUnsupported).count == 1)
    #expect(client.writeEvents.isEmpty)
}

@Test
@MainActor
func accessibilityServiceShowsNativeFullScreenInventoryWindowsAsUnsupported() {
    let client = FakeAccessibilityClient()
    let application = AccessibilityApplication(processIdentifier: 100)
    let nativeFullScreen = AccessibilityWindowHandle(token: "native-full-screen")
    let ordinaryUnavailable = AccessibilityWindowHandle(token: "ordinary-unavailable")
    client.appValues = [application]
    client.handlesByPID[application.processIdentifier] = [nativeFullScreen, ordinaryUnavailable]
    client.visibleWindowValues = []
    client.attributesByToken[nativeFullScreen.token] = serviceAttributes(
        presentationState: WindowPresentationState(isFullScreen: true, canToggleFullScreen: true)
    )
    client.attributesByToken[ordinaryUnavailable.token] = serviceAttributes(
        position: CGPoint(x: 1_200, y: 100)
    )

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let inventory = service.inventory(displays: serviceDisplays.enumerated().map {
        InventoryDisplay(snapshot: $0.element, ordinal: $0.offset + 1, name: nil)
    })

    #expect(inventory.windows.count == 2)
    #expect(inventory.windows.map(\.isAutomaticallyIncluded) == [false, false])
    #expect(inventory.windows.map(\.isNativeFullScreenUnsupported) == [true, false])
    #expect(inventory.windows.allSatisfy { !$0.isSelectable })
}

@Test
@MainActor
func accessibilityServiceUsesFullTopologyBeforeFilteringToSelectedPair() {
    let client = FakeAccessibilityClient()
    let application = AccessibilityApplication(processIdentifier: 100)
    let onFirst = AccessibilityWindowHandle(token: "on-first")
    let onUnselected = AccessibilityWindowHandle(token: "on-unselected")
    let onThird = AccessibilityWindowHandle(token: "on-third")
    let spanningUnselectedAndThird = AccessibilityWindowHandle(token: "spanning-unselected-third")
    let nativeFullScreenUnselected = AccessibilityWindowHandle(token: "native-full-screen-unselected")
    client.appValues = [application]
    client.handlesByPID[application.processIdentifier] = [
        onFirst, onUnselected, onThird, spanningUnselectedAndThird, nativeFullScreenUnselected
    ]
    let activeDisplays = [
        DisplaySnapshot(id: 1, frame: CGRect(x: 0, y: 0, width: 1_000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)),
        DisplaySnapshot(id: 2, frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800), visibleFrame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800)),
        DisplaySnapshot(id: 3, frame: CGRect(x: 2_000, y: 0, width: 1_000, height: 800), visibleFrame: CGRect(x: 2_000, y: 0, width: 1_000, height: 800))
    ]
    client.attributesByToken[onFirst.token] = serviceAttributes(position: CGPoint(x: 100, y: 100))
    client.attributesByToken[onUnselected.token] = serviceAttributes(position: CGPoint(x: 1_100, y: 100))
    client.attributesByToken[onThird.token] = serviceAttributes(position: CGPoint(x: 2_100, y: 100))
    client.attributesByToken[spanningUnselectedAndThird.token] = serviceAttributes(
        position: CGPoint(x: 1_900, y: 100),
        size: CGSize(width: 300, height: 200)
    )
    client.attributesByToken[nativeFullScreenUnselected.token] = serviceAttributes(
        position: CGPoint(x: 1_000, y: 0),
        size: CGSize(width: 1_000, height: 800),
        presentationState: WindowPresentationState(isFullScreen: true, canToggleFullScreen: true)
    )
    client.visibleWindowValues = [
        VisibleWindowSnapshot(processIdentifier: 100, frame: CGRect(x: 100, y: 100, width: 300, height: 200), windowNumber: 1),
        VisibleWindowSnapshot(processIdentifier: 100, frame: CGRect(x: 1_100, y: 100, width: 300, height: 200), windowNumber: 2),
        VisibleWindowSnapshot(processIdentifier: 100, frame: CGRect(x: 2_100, y: 100, width: 300, height: 200), windowNumber: 3),
        VisibleWindowSnapshot(processIdentifier: 100, frame: CGRect(x: 1_900, y: 100, width: 300, height: 200), windowNumber: 4)
    ]

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(activeDisplays: activeDisplays, selectedDisplays: [activeDisplays[0], activeDisplays[2]])

    #expect(batch.windows.map(\.snapshot.sourceDisplayID).sorted() == [1, 3])
    #expect(batch.skipped.filter { $0.reason == .unselectedDisplay }.count == 1)
    #expect(batch.skipped.filter { $0.reason == .spanningDisplays }.count == 1)
    #expect(batch.skipped.contains(WindowSkip(processIdentifier: 100, reason: .nativeFullScreenSpace)))
    #expect(batch.knownRuntimeKeys == [
        RuntimeWindowKey(processIdentifier: 100, quartzWindowNumber: 1),
        RuntimeWindowKey(processIdentifier: 100, quartzWindowNumber: 2),
        RuntimeWindowKey(processIdentifier: 100, quartzWindowNumber: 3)
    ])
    #expect(client.writeEvents.isEmpty)
}

@Test
@MainActor
func accessibilityServiceSkipsNativeFullScreenBeforeAnyWrite() {
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
    #expect(batch.windows.isEmpty)
    #expect(batch.skipped.contains(WindowSkip(processIdentifier: 100, reason: .nativeFullScreenSpace)))
    #expect(client.writeEvents.isEmpty)
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
        #expect(moves.count == 1)
        for move in moves {
            let captured = batch.windows.first { $0.snapshot.id == move.windowID }!
            #expect(service.apply(move: move, isResizable: captured.isResizable) == .success)
        }
    }

    let nativeFrame = mainDisplay.frame
    for _ in 0..<4 {
        swapOnce()
    }
    #expect(client.attributesByToken[nativeFullScreen.token]!.presentationState.isFullScreen == true)
    #expect(CGRect(
        origin: client.attributesByToken[nativeFullScreen.token]!.position,
        size: client.attributesByToken[nativeFullScreen.token]!.size
    ) == nativeFrame)
    #expect(client.attributesByToken[windowedFullScreen.token]!.presentationState.isFullScreen != true)
    #expect(CGRect(
        origin: client.attributesByToken[windowedFullScreen.token]!.position,
        size: client.attributesByToken[windowedFullScreen.token]!.size
    ) == secondDisplay.visibleFrame)
    #expect(!client.writeEvents.contains { $0.contains(nativeFullScreen.token) })
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

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    let ordinaryID = batch.windows.first { $0.presentationState == .unknown }!.snapshot.id

    #expect(batch.skipped.contains(WindowSkip(processIdentifier: 100, reason: .nativeFullScreenSpace)))
    #expect(service.apply(
        move: WindowMove(windowID: ordinaryID, destinationDisplayID: 1, frame: CGRect(x: 100, y: 100, width: 300, height: 200)),
        isResizable: true
    ) == .success)
    #expect(client.writeEvents == ["size:ordinary:300.0x200.0", "position:ordinary:100.0,100.0"])
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
        position: serviceDisplays[0].visibleFrame.origin, size: serviceDisplays[0].visibleFrame.size,
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


/// Realistic same-app tiles expose a truthy zoom control without being maximized.
@Test(arguments: [2, 4])
@MainActor
func ambiguousZoomTilesRetainDistinctGeometryAndIdentityForFourSwaps(tileCount: Int) async {
    let displays = [
        DisplaySnapshot(id: 10, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                        visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 968)),
        DisplaySnapshot(id: 20, frame: CGRect(x: 1920, y: 267, width: 1280, height: 800),
                        visibleFrame: CGRect(x: 1920, y: 297, width: 1280, height: 770))
    ]
    func frames(on display: DisplaySnapshot) -> [CGRect] {
        let f = display.visibleFrame
        return (0..<tileCount).map { index in
            CGRect(x: f.minX + CGFloat(index % 2) * f.width / 2,
                   y: f.minY + CGFloat(index / 2) * f.height / 2,
                   width: f.width / 2, height: tileCount == 2 ? f.height : f.height / 2)
        }
    }
    let client = FakeAccessibilityClient()
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    let handles = (0..<tileCount).map { AccessibilityWindowHandle(token: "tile-\($0)") }
    client.handlesByPID[100] = handles
    for (index, handle) in handles.enumerated() {
        let frame = frames(on: displays[0])[index]
        client.attributesByToken[handle.token] = serviceAttributes(
            position: frame.origin, size: frame.size,
            presentationState: WindowPresentationState(isZoomed: true, canToggleZoom: true))
        client.windowNumbersByToken[handle.token] = UInt32(41 + index)
    }
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let coordinator = SwapCoordinator(authorization: TileAuthorizer(), displays: TileDisplays(values: displays),
                                      windowProvider: service, windowApplying: service, windowVerifier: service)
    for invocation in 1...4 {
        let result = await coordinator.swapMeasured()
        #expect(result.outcome == .success(attempted: tileCount, succeeded: tileCount))
        #expect(coordinator.lastDiagnostics.planned == tileCount)
        let destination = displays[invocation.isMultiple(of: 2) ? 0 : 1]
        let expected = frames(on: destination)
        for (index, handle) in handles.enumerated() {
            let attributes = client.attributesByToken[handle.token]!
            #expect(CGRect(origin: attributes.position, size: attributes.size) == expected[index])
        }
        let visible = try! client.visibleWindows()
        #expect(visible.count == tileCount)
        #expect(Set(visible.compactMap(\.windowNumber)).count == tileCount)
        #expect(Set(visible.map { "\($0.frame)" }).count == tileCount)
    }
    #expect(!client.writeEvents.contains { $0.hasPrefix("zoom:") || $0.hasPrefix("raise:") })
}

@MainActor
private final class TileAuthorizer: AccessibilityAuthorizing {
    var isTrusted = true
    func requestAccess() {}
}

@MainActor
private final class TileDisplays: DisplayProviding {
    let values: [DisplaySnapshot]
    init(values: [DisplaySnapshot]) { self.values = values }
    func currentDisplays() throws -> [DisplaySnapshot] { values }
}

@Test(arguments: [false, true])
@MainActor
func overlappingSameAppWindowsVerifyOnlyTheirOwnQuartzIdentity(hideSecond: Bool) {
    let client = FakeAccessibilityClient()
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    let handles = [AccessibilityWindowHandle(token: "overlap-41"), AccessibilityWindowHandle(token: "overlap-42")]
    client.handlesByPID[100] = handles
    for (index, handle) in handles.enumerated() {
        client.attributesByToken[handle.token] = serviceAttributes()
        client.windowNumbersByToken[handle.token] = UInt32(41 + index)
    }
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    let moves = WindowMappingEngine().makeSwapMoves(windows: batch.windows.map(\.snapshot),
                                                   displayA: serviceDisplays[0], displayB: serviceDisplays[1])
    #expect(moves.count == 2)
    for move in moves { #expect(service.apply(move: move, isResizable: true) == .success) }
    #expect(moves[0].frame == moves[1].frame)
    if hideSecond { client.hiddenTokens.insert(handles[1].token) }
    #expect(service.verificationStatus(for: moves[0], isResizable: true, tolerance: 2) == .verified)
    #expect(service.verificationStatus(for: moves[1], isResizable: true, tolerance: 2) ==
            (hideSecond ? .notVisible : .verified))
}

@Test
@MainActor
func batchVerificationUsesOneQuartzSnapshotForEightWindows() {
    let client = FakeAccessibilityClient()
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    let handles = (0..<8).map { AccessibilityWindowHandle(token: "batch-\($0)") }
    client.handlesByPID[100] = handles
    for (index, handle) in handles.enumerated() {
        let frame = CGRect(x: CGFloat(index * 100), y: 20, width: 80, height: 80)
        client.attributesByToken[handle.token] = serviceAttributes(position: frame.origin, size: frame.size)
        client.windowNumbersByToken[handle.token] = UInt32(41 + index)
    }
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    client.visibleWindowsCallCount = 0
    client.frameReadCount = 0
    client.attributesReadCount = 0
    let candidates = batch.windows.map { captured in
        (WindowMove(windowID: captured.snapshot.id, destinationDisplayID: captured.snapshot.sourceDisplayID, frame: captured.snapshot.frame), captured.isResizable)
    }

    let statuses = service.verificationStatuses(for: candidates, tolerance: 2)

    #expect(statuses.values.allSatisfy { $0 == .verified })
    #expect(client.visibleWindowsCallCount == 1)
    #expect(client.frameReadCount == 8)
    #expect(client.attributesReadCount == 0)
}

@Test
@MainActor
func recaptureReplacesQuartzIdentitiesAndRejectsStaleMoves() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "reused-handle")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes()
    client.windowNumbersByToken[handle.token] = 41
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let old = service.captureWindows(displays: serviceDisplays).windows[0]
    client.windowNumbersByToken[handle.token] = 42
    let current = service.captureWindows(displays: serviceDisplays).windows[0]
    client.windowNumbersByToken[handle.token] = 41
    let move = WindowMove(windowID: current.snapshot.id, destinationDisplayID: 1, frame: current.snapshot.frame)
    #expect(service.verificationStatus(for: move, isResizable: true, tolerance: 2) == .notVisible)
    #expect(service.verificationStatus(for: WindowMove(windowID: old.snapshot.id, destinationDisplayID: 1,
                                                   frame: old.snapshot.frame), isResizable: true, tolerance: 2) == .unavailable)
}


@Test
@MainActor
func retiledMaximizedWindowDropsRetainedIntentEvenWithTruthyZoomControl() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "retiled")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.windowNumbersByToken[handle.token] = 41
    client.attributesByToken[handle.token] = serviceAttributes(position: .zero, size: serviceDisplays[0].visibleFrame.size)
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    #expect(service.captureWindows(displays: serviceDisplays).windows[0].isVisuallyMaximized)
    client.attributesByToken[handle.token] = serviceAttributes(
        position: .zero, size: CGSize(width: 500, height: 800),
        presentationState: WindowPresentationState(isZoomed: true, canToggleZoom: true))
    let batch = service.captureWindows(displays: serviceDisplays)
    #expect(!batch.windows[0].isVisuallyMaximized)
    let move = WindowMappingEngine().makeSwapMoves(windows: batch.windows.map(\.snapshot),
        displayA: serviceDisplays[0], displayB: serviceDisplays[1])[0]
    #expect(service.apply(move: move, isResizable: true) == .success)
    #expect(client.attributesByToken[handle.token]!.size == CGSize(width: 500, height: 800))
    #expect(!client.writeEvents.contains { $0.hasPrefix("zoom:") })
    #expect(service.restore(windowID: move.windowID, isResizable: true) == .success)
    #expect(!client.writeEvents.contains { $0.hasPrefix("zoom:") })
}


@Test(arguments: [false, true])
@MainActor
func geometryUpdatesSuspendEnhancedUIAndRestoreItOnSuccessOrFailure(failWrite: Bool) {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "animated-tile")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes(position: .zero, size: CGSize(width: 500, height: 800))
    client.enhancedUIEnabled = true
    client.failingPositionWrites = failWrite
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let id = service.captureWindows(displays: serviceDisplays).windows[0].snapshot.id
    let target = CGRect(x: 1000, y: 0, width: 400, height: 700)
    let result = service.apply(move: WindowMove(windowID: id, destinationDisplayID: 2, frame: target), isResizable: true)
    #expect(result.succeeded == !failWrite)
    #expect(client.attributesByToken[handle.token]!.size == target.size)
    #expect(client.enhancedUIEnabled)
    #expect(!client.writeEvents.contains { $0.hasPrefix("zoom:") || $0.hasPrefix("raise:") })
}

@Test
@MainActor
func rollbackSuspendsEnhancedUIAndRestoresTheOriginalFrame() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "rollback-animated-tile")
    let source = CGRect(x: 0, y: 0, width: 500, height: 800)
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes(position: source.origin, size: source.size)
    client.enhancedUIEnabled = true
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let captured = service.captureWindows(displays: serviceDisplays).windows[0]
    let destination = CGRect(x: 1_000, y: 0, width: 400, height: 700)
    let move = WindowMove(windowID: captured.snapshot.id, destinationDisplayID: 2, frame: destination)
    #expect(service.apply(move: move, isResizable: true) == .success)
    #expect(client.attributesByToken[handle.token]!.position == destination.origin)
    #expect(service.restore(windowID: move.windowID, isResizable: true) == .success)
    #expect(client.attributesByToken[handle.token]!.position == source.origin)
    #expect(client.attributesByToken[handle.token]!.size == source.size)
    #expect(client.enhancedUIEnabled)
}

@Test
@MainActor
func geometryUpdatesKeepEnhancedUIWhenAssistiveTechnologyIsActive() {
    var enabled = true
    var writes = 0
    let result = AccessibilityGeometryUpdateScope.perform(assistiveTechnologyActive: true,
        readEnhancedUI: { enabled }, writeEnhancedUI: { enabled = $0; writes += 1; return true },
        updates: { #expect(enabled); return .success })
    #expect(result == .success)
    #expect(writes == 0)
    #expect(enabled)
}


@Test(arguments: [0.02, 0.8])
@MainActor
func keyedStageManagerThumbnailDoesNotVerifyFullSizeDestinationWindow(scale: Double) {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "stage-hidden")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes()
    client.windowNumbersByToken[handle.token] = 41
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let captured = service.captureWindows(displays: serviceDisplays).windows[0]
    let destination = CGRect(x: 1100, y: 100, width: 300, height: 200)
    let move = WindowMove(windowID: captured.snapshot.id, destinationDisplayID: 2, frame: destination)
    #expect(service.apply(move: move, isResizable: true) == .success)
    client.visibleWindowValues = [VisibleWindowSnapshot(processIdentifier: 100,
        frame: CGRect(x: 1100, y: 100, width: 300 * scale, height: 200 * scale), windowNumber: 41)]
    #expect(service.verificationStatus(for: move, isResizable: true, tolerance: 2) == .notVisible)
    #expect(service.restore(windowID: move.windowID, isResizable: true) == .success)
    #expect(client.attributesByToken[handle.token]!.position == captured.snapshot.frame.origin)
}

@Test
@MainActor
func nativeTileDecorationAtSharedBoundaryDoesNotBecomeASpanningWindow() {
    let client = FakeAccessibilityClient()
    let handles = [AccessibilityWindowHandle(token: "decorated-left"), AccessibilityWindowHandle(token: "decorated-right"),
                   AccessibilityWindowHandle(token: "genuine-span")]
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = handles
    client.attributesByToken[handles[0].token] = serviceAttributes(position: .zero, size: CGSize(width: 501, height: 800))
    client.attributesByToken[handles[1].token] = serviceAttributes(position: CGPoint(x: 501, y: 0), size: CGSize(width: 500, height: 800))
    client.attributesByToken[handles[2].token] = serviceAttributes(position: CGPoint(x: 800, y: 100), size: CGSize(width: 400, height: 300))
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let batch = service.captureWindows(displays: serviceDisplays)
    let moves = WindowMappingEngine().makeSwapMoves(windows: batch.windows.map(\.snapshot),
        displayA: serviceDisplays[0], displayB: serviceDisplays[1])
    #expect(moves.count == 2)
    #expect(moves.map(\.frame) == [CGRect(x: 1000, y: 0, width: 500, height: 800),
                                 CGRect(x: 1500, y: 0, width: 500, height: 800)])
    for move in moves { #expect(service.apply(move: move, isResizable: true) == .success) }
    #expect(!client.writeEvents.contains { $0.contains("genuine-span") })
}

@Test
@MainActor
func nativeZoomIsRestoredWhenDestinationResizeIsAcknowledgedButIgnored() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "zoom-resize-refused")
    let displays = [serviceDisplays[0], DisplaySnapshot(id: 2,
        frame: CGRect(x: 1000, y: 0, width: 1200, height: 900),
        visibleFrame: CGRect(x: 1000, y: 0, width: 1200, height: 900))]
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes(position: .zero,
        size: displays[0].visibleFrame.size,
        presentationState: WindowPresentationState(isZoomed: true, canToggleZoom: true))
    client.ignoresSizeWritesUntilZoom = true
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let id = service.captureWindows(displays: displays).windows[0].snapshot.id
    #expect(service.apply(move: WindowMove(windowID: id, destinationDisplayID: 2,
        frame: displays[1].visibleFrame), isResizable: true) == WindowApplyResult(succeeded: false, failure: .size))
    #expect(client.attributesByToken[handle.token]!.presentationState.isZoomed == true)
}


@Test(arguments: [false, true])
@MainActor
func measuredSwapRecoversExactHiddenWindowAndRechecksOtherWindows(hidesOther: Bool) async {
    let client = FakeAccessibilityClient()
    let handles = [AccessibilityWindowHandle(token: "stage-left"), AccessibilityWindowHandle(token: "stage-right")]
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = handles
    for (index, handle) in handles.enumerated() {
        client.attributesByToken[handle.token] = serviceAttributes(position: CGPoint(x: CGFloat(index) * 500, y: 0),
                                                                 size: CGSize(width: 500, height: 800))
        client.windowNumbersByToken[handle.token] = UInt32(41 + index)
    }
    client.hidesOnDestinationTokens = [handles[0].token]
    if hidesOther { client.hideAnotherOnRaise = handles[1].token }
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let coordinator = SwapCoordinator(authorization: TileAuthorizer(), displays: TileDisplays(values: serviceDisplays),
        windowProvider: service, windowApplying: service, windowRestorer: service,
        windowVerifier: service, windowVisibilityRecoverer: service)
    let result = await coordinator.swapMeasured()
    #expect(result.outcome == (hidesOther ? .partialFailure(attempted: 2, succeeded: 1, failed: 1)
                                        : .success(attempted: 2, succeeded: 2)))
    #expect(client.writeEvents.filter { $0.hasPrefix("raise:") } == ["raise:stage-left"])
    #expect(client.attributesByToken[handles[0].token]!.position == CGPoint(x: 1000, y: 0))
}

@Test
@MainActor
func visibilityRecoveryRequiresCorrectGeometryAndIsBoundedToOneAttempt() {
    let client = FakeAccessibilityClient()
    let handle = AccessibilityWindowHandle(token: "bounded-recovery")
    client.appValues = [AccessibilityApplication(processIdentifier: 100)]
    client.handlesByPID[100] = [handle]
    client.attributesByToken[handle.token] = serviceAttributes()
    client.windowNumbersByToken[handle.token] = 41
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let id = service.captureWindows(displays: serviceDisplays).windows[0].snapshot.id
    let move = WindowMove(windowID: id, destinationDisplayID: 2, frame: CGRect(x: 1100, y: 100, width: 300, height: 200))
    #expect(!service.recoverVisibility(for: move, isResizable: true).succeeded)
    #expect(client.writeEvents.isEmpty)
    #expect(service.apply(move: move, isResizable: true) == .success)
    client.hiddenTokens = [handle.token]
    client.failingRaiseActions = true
    #expect(!service.recoverVisibility(for: move, isResizable: true).succeeded)
    #expect(!service.recoverVisibility(for: move, isResizable: true).succeeded)
    #expect(client.writeEvents.filter { $0.hasPrefix("raise:") }.count == 1)
}
