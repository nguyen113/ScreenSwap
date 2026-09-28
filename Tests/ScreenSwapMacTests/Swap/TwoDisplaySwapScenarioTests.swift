import CoreGraphics
import Foundation
import ScreenSwapCore
import Testing
@testable import ScreenSwapMac

@MainActor
private final class TwoDisplaySwapScenarioAccessibilityClient: AccessibilityClient {
    var applicationValues: [AccessibilityApplication] = []
    var handlesByProcess: [Int32: [AccessibilityWindowHandle]] = [:]
    var attributesByToken: [String: AccessibilityWindowAttributes] = [:]
    var hiddenTokens: Set<String> = []
    var events: [String] = []
    var writeEvents: [String] = []
    var failingPositionTokens: Set<String> = []
    /// Models the window-server behavior that caps a size write while the
    /// window is still positioned on a smaller display.
    var constrainsGrowthWithinCurrentDisplay = false
    var sizeConstraintDisplays: [DisplaySnapshot] = []
    /// Models a window manager that reports one point less than requested
    /// when a tile is resized on a particular display.
    var reportedHeightReductionDisplayID: UInt32?
    /// Models a tiled window whose first AX size write is acknowledged but
    /// ignored until it has been moved onto the destination display.
    var requiresPositionBeforeResizingTokens: Set<String> = []
    private var positionedTokens: Set<String> = []

    func beginCapture() {
        events.append("beginCapture")
    }

    func applications() throws -> [AccessibilityApplication] {
        events.append("applications")
        return applicationValues
    }

    func visibleWindows() throws -> [VisibleWindowSnapshot] {
        events.append("visibleWindows")
        return applicationValues.flatMap { application in
            (handlesByProcess[application.processIdentifier] ?? []).compactMap { handle in
                guard !hiddenTokens.contains(handle.token),
                      let attributes = attributesByToken[handle.token] else {
                    return nil
                }
                return VisibleWindowSnapshot(
                    processIdentifier: application.processIdentifier,
                    frame: CGRect(origin: attributes.position, size: attributes.size)
                )
            }
        }
    }

    func windows(for application: AccessibilityApplication) throws -> [AccessibilityWindowHandle] {
        events.append("windows:\(application.processIdentifier)")
        return handlesByProcess[application.processIdentifier] ?? []
    }

    func attributes(for window: AccessibilityWindowHandle) throws -> AccessibilityWindowAttributes {
        events.append("read:\(window.token)")
        guard let attributes = attributesByToken[window.token] else {
            throw AccessibilityClientError.attributeReadFailed
        }
        return attributes
    }

    func setSize(_ size: CGSize, for window: AccessibilityWindowHandle) throws {
        events.append("size:\(window.token)")
        writeEvents.append("size:\(window.token)")
        if requiresPositionBeforeResizingTokens.contains(window.token),
           !positionedTokens.contains(window.token) {
            return
        }
        let currentDisplay = attributesByToken[window.token].flatMap { current in
            sizeConstraintDisplays.first(where: {
                $0.frame.contains(CGPoint(x: current.position.x + current.size.width / 2,
                                          y: current.position.y + current.size.height / 2))
            })
        }
        let constrainedSize: CGSize
        if constrainsGrowthWithinCurrentDisplay,
           let currentDisplay {
            constrainedSize = CGSize(
                width: min(size.width, currentDisplay.visibleFrame.width),
                height: min(size.height, currentDisplay.visibleFrame.height)
            )
        } else {
            constrainedSize = size
        }
        update(window.token, size: constrainedSize)
    }

    func setPosition(_ position: CGPoint, for window: AccessibilityWindowHandle) throws {
        events.append("position:\(window.token)")
        writeEvents.append("position:\(window.token)")
        if failingPositionTokens.contains(window.token) {
            throw AccessibilityClientError.writeFailed
        }
        update(window.token, position: position)
        positionedTokens.insert(window.token)
        if let reportedHeightReductionDisplayID,
           let current = attributesByToken[window.token],
           let display = sizeConstraintDisplays.first(where: { $0.id == reportedHeightReductionDisplayID }),
           display.frame.contains(position),
           current.size.height >= display.visibleFrame.height {
            update(window.token, size: CGSize(width: current.size.width, height: current.size.height - 1))
        }
    }

    func raise(_ window: AccessibilityWindowHandle) throws {
        events.append("raise:\(window.token)")
    }

    func pressZoom(for window: AccessibilityWindowHandle) throws {
        events.append("zoom:\(window.token)")
        guard let state = attributesByToken[window.token]?.presentationState.isZoomed else {
            throw AccessibilityClientError.actionFailed
        }
        updatePresentation(window.token, zoomed: !state)
    }

    func pressFullScreen(for window: AccessibilityWindowHandle) throws {
        events.append("fullScreen:\(window.token)")
        guard let state = attributesByToken[window.token]?.presentationState.isFullScreen else {
            throw AccessibilityClientError.actionFailed
        }
        updatePresentation(window.token, fullScreen: !state)
    }

    private func update(_ token: String, position: CGPoint? = nil, size: CGSize? = nil) {
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
private final class TwoDisplaySwapScenarioAuthorizer: AccessibilityAuthorizing {
    var isTrusted = true

    func requestAccess() {}
}

@MainActor
private final class TwoDisplaySwapScenarioDisplayProvider: DisplayProviding {
    let values: [DisplaySnapshot]

    init(values: [DisplaySnapshot]) {
        self.values = values
    }

    func currentDisplays() throws -> [DisplaySnapshot] {
        values
    }
}

private struct TwoDisplaySwapScenarioWindow {
    let token: String
    let processIdentifier: Int32
    let bundleIdentifier: String
    let initialFrame: CGRect
    let expectedFrame: CGRect
}

private func scenarioAttributes(frame: CGRect) -> AccessibilityWindowAttributes {
    AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: frame.origin,
        size: frame.size,
        positionIsSettable: true,
        sizeIsSettable: true
    )
}

private func expectApproximatelyEqual(_ actual: CGRect, _ expected: CGRect) {
    let tolerance: CGFloat = 0.001
    #expect(abs(actual.minX - expected.minX) <= tolerance)
    #expect(abs(actual.minY - expected.minY) <= tolerance)
    #expect(abs(actual.width - expected.width) <= tolerance)
    #expect(abs(actual.height - expected.height) <= tolerance)
}

@Test
@MainActor
func twoDisplaySwapMovesAllVisibleWindowsAcrossApplicationsAndVariousSizes() {
    let displayA = DisplaySnapshot(
        id: 10,
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
    )
    let displayB = DisplaySnapshot(
        id: 20,
        frame: CGRect(x: 1000, y: 0, width: 2000, height: 1600),
        visibleFrame: CGRect(x: 1000, y: 0, width: 2000, height: 1600)
    )

    let windows = [
        TwoDisplaySwapScenarioWindow(
            token: "notes-small",
            processIdentifier: 101,
            bundleIdentifier: "com.apple.Notes",
            initialFrame: CGRect(x: 100, y: 100, width: 200, height: 160),
            expectedFrame: CGRect(x: 1200, y: 200, width: 400, height: 320)
        ),
        TwoDisplaySwapScenarioWindow(
            token: "safari-large",
            processIdentifier: 202,
            bundleIdentifier: "com.apple.Safari",
            initialFrame: CGRect(x: 400, y: 200, width: 500, height: 400),
            expectedFrame: CGRect(x: 1800, y: 400, width: 1000, height: 800)
        ),
        TwoDisplaySwapScenarioWindow(
            token: "notes-medium",
            processIdentifier: 101,
            bundleIdentifier: "com.apple.Notes",
            initialFrame: CGRect(x: 1200, y: 200, width: 400, height: 320),
            expectedFrame: CGRect(x: 100, y: 100, width: 200, height: 160)
        ),
        TwoDisplaySwapScenarioWindow(
            token: "safari-tall",
            processIdentifier: 202,
            bundleIdentifier: "com.apple.Safari",
            initialFrame: CGRect(x: 2000, y: 400, width: 800, height: 800),
            expectedFrame: CGRect(x: 500, y: 200, width: 400, height: 400)
        )
    ]

    let client = TwoDisplaySwapScenarioAccessibilityClient()
    let notes = AccessibilityApplication(
        processIdentifier: 101,
        bundleIdentifier: "com.apple.Notes"
    )
    let safari = AccessibilityApplication(
        processIdentifier: 202,
        bundleIdentifier: "com.apple.Safari"
    )
    client.applicationValues = [notes, safari]
    client.handlesByProcess[notes.processIdentifier] = windows
        .filter { $0.processIdentifier == notes.processIdentifier }
        .map { AccessibilityWindowHandle(token: $0.token) }
    client.handlesByProcess[safari.processIdentifier] = windows
        .filter { $0.processIdentifier == safari.processIdentifier }
        .map { AccessibilityWindowHandle(token: $0.token) }
    for window in windows {
        client.attributesByToken[window.token] = scenarioAttributes(frame: window.initialFrame)
    }

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let coordinator = SwapCoordinator(
        authorization: TwoDisplaySwapScenarioAuthorizer(),
        // Deliberately return the displays in reverse order. Stable IDs, not
        // provider array order, choose display A and display B.
        displays: TwoDisplaySwapScenarioDisplayProvider(values: [displayB, displayA]),
        windowProvider: service,
        windowApplying: service
    )

    #expect(coordinator.swap() == .success(attempted: 4, succeeded: 4))

    for window in windows {
        guard let attributes = client.attributesByToken[window.token] else {
            Issue.record("Missing final attributes for (window.token)")
            continue
        }
        expectApproximatelyEqual(CGRect(origin: attributes.position, size: attributes.size), window.expectedFrame)
    }

    #expect(client.writeEvents == [
        "size:notes-small", "position:notes-small",
        "size:notes-medium", "position:notes-medium",
        "size:safari-large", "position:safari-large",
        "size:safari-tall", "position:safari-tall"
    ])
    #expect(client.events.prefix(4) == [
        "applications", "visibleWindows", "beginCapture", "windows:101"
    ])
    #expect(client.events.contains("windows:202"))

    let firstWriteIndex = client.events.firstIndex { event in
        event.hasPrefix("size:") || event.hasPrefix("position:")
    }
    #expect(firstWriteIndex != nil)
    if let firstWriteIndex {
        #expect(client.events[..<firstWriteIndex].filter { $0.hasPrefix("read:") } == [
            "read:notes-small", "read:notes-medium", "read:safari-large", "read:safari-tall"
        ])
    }
}

private struct StatefulSwapFixture {
    let client: TwoDisplaySwapScenarioAccessibilityClient
    let coordinator: SwapCoordinator
    let displayA: DisplaySnapshot
    let displayB: DisplaySnapshot
    let ordinaryToken: String
    let zoomedToken: String
    let inactiveToken: String
    let ordinaryInitialFrame: CGRect
    let zoomedInitialFrame: CGRect
    let inactiveInitialFrame: CGRect
}

@MainActor
private func makeStatefulSwapFixture() -> StatefulSwapFixture {
    let displayA = DisplaySnapshot(
        id: 10,
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
    )
    let displayB = DisplaySnapshot(
        id: 20,
        frame: CGRect(x: 1000, y: 0, width: 1200, height: 900),
        visibleFrame: CGRect(x: 1000, y: 40, width: 1200, height: 860)
    )
    let active = AccessibilityApplication(processIdentifier: 101, bundleIdentifier: "com.apple.Notes")
    let inactive = AccessibilityApplication(processIdentifier: 202, bundleIdentifier: "com.apple.Safari")
    let ordinaryToken = "stateful-ordinary"
    let zoomedToken = "stateful-zoomed"
    let inactiveToken = "stateful-inactive-stage-manager"
    let ordinaryInitialFrame = CGRect(x: 100, y: 120, width: 300, height: 200)
    let zoomedInitialFrame = displayB.visibleFrame
    let inactiveInitialFrame = CGRect(x: 300, y: 500, width: 300, height: 200)

    let client = TwoDisplaySwapScenarioAccessibilityClient()
    client.applicationValues = [active, inactive]
    let ordinary = AccessibilityWindowHandle(token: ordinaryToken)
    let zoomed = AccessibilityWindowHandle(token: zoomedToken)
    let inactiveWindow = AccessibilityWindowHandle(token: inactiveToken)
    client.handlesByProcess[active.processIdentifier] = [ordinary, zoomed]
    client.handlesByProcess[inactive.processIdentifier] = [inactiveWindow]
    client.attributesByToken[ordinaryToken] = scenarioAttributes(frame: ordinaryInitialFrame)
    client.attributesByToken[zoomedToken] = AccessibilityWindowAttributes(
        role: "AXWindow",
        isMinimized: false,
        position: zoomedInitialFrame.origin,
        size: zoomedInitialFrame.size,
        positionIsSettable: true,
        sizeIsSettable: true,
        presentationState: WindowPresentationState(isZoomed: true, canToggleZoom: true)
    )
    client.attributesByToken[inactiveToken] = scenarioAttributes(frame: inactiveInitialFrame)
    client.hiddenTokens = [inactiveToken]

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let coordinator = SwapCoordinator(
        authorization: TwoDisplaySwapScenarioAuthorizer(),
        displays: TwoDisplaySwapScenarioDisplayProvider(values: [displayB, displayA]),
        windowProvider: service,
        windowApplying: service
    )
    return StatefulSwapFixture(
        client: client,
        coordinator: coordinator,
        displayA: displayA,
        displayB: displayB,
        ordinaryToken: ordinaryToken,
        zoomedToken: zoomedToken,
        inactiveToken: inactiveToken,
        ordinaryInitialFrame: ordinaryInitialFrame,
        zoomedInitialFrame: zoomedInitialFrame,
        inactiveInitialFrame: inactiveInitialFrame
    )
}

@MainActor
private func currentFrame(
    for token: String,
    in client: TwoDisplaySwapScenarioAccessibilityClient
) -> CGRect {
    let attributes = client.attributesByToken[token]!
    return CGRect(origin: attributes.position, size: attributes.size)
}

private func plannedNormalFrame(
    from frame: CGRect,
    displayA: DisplaySnapshot,
    displayB: DisplaySnapshot
) -> CGRect {
    let engine = WindowMappingEngine()
    let snapshot = WindowSnapshot(
        id: WindowID(processIdentifier: 101, accessibilityIdentifier: "expected"),
        sourceDisplayID: engine.sourceDisplayID(for: frame, displayA: displayA, displayB: displayB),
        frame: frame
    )
    return engine.makeSwapMoves(windows: [snapshot], displayA: displayA, displayB: displayB)[0].frame
}

@Test
@MainActor
func fourStatefulSwapsRoundTripActiveWindowsAndLeaveInactiveStageManagerUntouched() {
    let fixture = makeStatefulSwapFixture()

    for invocation in 1...4 {
        let ordinaryBefore = currentFrame(for: fixture.ordinaryToken, in: fixture.client)
        let ordinaryExpected = plannedNormalFrame(
            from: ordinaryBefore,
            displayA: fixture.displayA,
            displayB: fixture.displayB
        )
        let zoomedBefore = currentFrame(for: fixture.zoomedToken, in: fixture.client)
        let zoomedSource = WindowMappingEngine().sourceDisplayID(
            for: zoomedBefore,
            displayA: fixture.displayA,
            displayB: fixture.displayB
        )
        let zoomedExpected = zoomedSource == fixture.displayA.id
            ? fixture.displayB.visibleFrame
            : fixture.displayA.visibleFrame
        let eventStart = fixture.client.events.count

        #expect(fixture.coordinator.swap() == .success(attempted: 2, succeeded: 2))
        #expect(fixture.coordinator.lastDiagnostics == SwapDiagnostics(
            discovered: 3,
            eligible: 2,
            selected: 2,
            skippedByReason: ["notVisible": 1],
            planned: 2,
            attempted: 2,
            succeeded: 2,
            failed: 0
        ))

        expectApproximatelyEqual(
            currentFrame(for: fixture.ordinaryToken, in: fixture.client),
            ordinaryExpected
        )
        expectApproximatelyEqual(
            currentFrame(for: fixture.zoomedToken, in: fixture.client),
            zoomedExpected
        )
        expectApproximatelyEqual(
            currentFrame(for: fixture.inactiveToken, in: fixture.client),
            fixture.inactiveInitialFrame
        )
        #expect(fixture.client.attributesByToken[fixture.ordinaryToken]!.presentationState == .unknown)
        #expect(fixture.client.attributesByToken[fixture.zoomedToken]!.presentationState ==
            WindowPresentationState(isZoomed: true, canToggleZoom: true))

        let invocationEvents = fixture.client.events.dropFirst(eventStart)
        #expect(invocationEvents.contains("windows:101"))
        #expect(invocationEvents.contains("windows:202"))
        #expect(!invocationEvents.contains("zoom:\(fixture.ordinaryToken)"))

        if invocation == 2 || invocation == 4 {
            expectApproximatelyEqual(
                currentFrame(for: fixture.ordinaryToken, in: fixture.client),
                fixture.ordinaryInitialFrame
            )
            expectApproximatelyEqual(
                currentFrame(for: fixture.zoomedToken, in: fixture.client),
                fixture.zoomedInitialFrame
            )
        }
        fixture.client.writeEvents.removeAll()
    }

    #expect(fixture.client.applicationValues.count == 2)
}

@Test
@MainActor
func fourSwapsRetainWindowedFullScreenAndFiftyFiftyTiling() {
    let displayA = DisplaySnapshot(
        id: 10,
        frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
        visibleFrame: CGRect(x: 0, y: 24, width: 1_440, height: 876)
    )
    let displayB = DisplaySnapshot(
        id: 20,
        frame: CGRect(x: 1_440, y: 0, width: 2_560, height: 1_440),
        visibleFrame: CGRect(x: 1_440, y: 0, width: 2_560, height: 1_440)
    )
    let fullScreen = AccessibilityWindowHandle(token: "windowed-full-screen")
    let leadingTile = AccessibilityWindowHandle(token: "leading-half")
    let trailingTile = AccessibilityWindowHandle(token: "trailing-half")
    let application = AccessibilityApplication(
        processIdentifier: 101,
        bundleIdentifier: "com.apple.Terminal"
    )
    let initialFrames = [
        fullScreen.token: CGRect(
            x: displayA.visibleFrame.minX,
            y: displayA.visibleFrame.minY,
            width: displayA.visibleFrame.width,
            height: displayA.visibleFrame.height - 1
        ),
        leadingTile.token: CGRect(x: 1_440, y: 0, width: 1_280, height: 1_440),
        trailingTile.token: CGRect(x: 2_720, y: 0, width: 1_280, height: 1_440)
    ]
    let client = TwoDisplaySwapScenarioAccessibilityClient()
    client.applicationValues = [application]
    client.handlesByProcess[application.processIdentifier] = [fullScreen, leadingTile, trailingTile]
    client.constrainsGrowthWithinCurrentDisplay = true
    client.sizeConstraintDisplays = [displayA, displayB]
    client.reportedHeightReductionDisplayID = displayA.id
    for (token, frame) in initialFrames {
        client.attributesByToken[token] = scenarioAttributes(frame: frame)
    }

    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let coordinator = SwapCoordinator(
        authorization: TwoDisplaySwapScenarioAuthorizer(),
        displays: TwoDisplaySwapScenarioDisplayProvider(values: [displayB, displayA]),
        windowProvider: service,
        windowApplying: service
    )

    for invocation in 1...4 {
        #expect(coordinator.swap() == .success(attempted: 3, succeeded: 3))

        let expectedDisplayForFullScreen = invocation.isMultiple(of: 2) ? displayA : displayB
        let expectedDisplayForTiles = invocation.isMultiple(of: 2) ? displayB : displayA
        let expectedFullScreenHeight = expectedDisplayForFullScreen.id == displayA.id
            ? expectedDisplayForFullScreen.visibleFrame.height - 1
            : expectedDisplayForFullScreen.visibleFrame.height
        expectApproximatelyEqual(currentFrame(for: fullScreen.token, in: client), CGRect(
            x: expectedDisplayForFullScreen.visibleFrame.minX,
            y: expectedDisplayForFullScreen.visibleFrame.minY,
            width: expectedDisplayForFullScreen.visibleFrame.width,
            height: expectedFullScreenHeight
        ))
        let expectedTileHeight = expectedDisplayForTiles.id == displayA.id
            ? expectedDisplayForTiles.visibleFrame.height - 1
            : expectedDisplayForTiles.visibleFrame.height
        expectApproximatelyEqual(currentFrame(for: leadingTile.token, in: client), CGRect(
            x: expectedDisplayForTiles.visibleFrame.minX,
            y: expectedDisplayForTiles.visibleFrame.minY,
            width: expectedDisplayForTiles.visibleFrame.width / 2,
            height: expectedTileHeight
        ))
        expectApproximatelyEqual(currentFrame(for: trailingTile.token, in: client), CGRect(
            x: expectedDisplayForTiles.visibleFrame.midX,
            y: expectedDisplayForTiles.visibleFrame.minY,
            width: expectedDisplayForTiles.visibleFrame.width / 2,
            height: expectedTileHeight
        ))
    }

    for (token, initialFrame) in initialFrames {
        expectApproximatelyEqual(currentFrame(for: token, in: client), initialFrame)
    }
}

@Test
@MainActor
func fourSwapsRetainFourQuarterScreenTiles() {
    let displayA = DisplaySnapshot(
        id: 10,
        frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        visibleFrame: CGRect(x: 0, y: 30, width: 1_920, height: 968)
    )
    let displayB = DisplaySnapshot(
        id: 20,
        frame: CGRect(x: 1_920, y: 267, width: 1_280, height: 800),
        visibleFrame: CGRect(x: 1_920, y: 297, width: 1_280, height: 770)
    )
    let tokens = ["top-leading", "top-trailing", "bottom-leading", "bottom-trailing"]
    let application = AccessibilityApplication(
        processIdentifier: 101,
        bundleIdentifier: "com.apple.Terminal"
    )
    func quarterFrames(on display: DisplaySnapshot) -> [CGRect] {
        let frame = display.visibleFrame
        return [
            CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height / 2),
            CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height / 2),
            CGRect(x: frame.minX, y: frame.midY, width: frame.width / 2, height: frame.height / 2),
            CGRect(x: frame.midX, y: frame.midY, width: frame.width / 2, height: frame.height / 2)
        ]
    }

    let client = TwoDisplaySwapScenarioAccessibilityClient()
    client.applicationValues = [application]
    client.handlesByProcess[application.processIdentifier] = tokens.map(AccessibilityWindowHandle.init)
    client.requiresPositionBeforeResizingTokens = Set(tokens)
    for (token, frame) in zip(tokens, quarterFrames(on: displayB)) {
        client.attributesByToken[token] = scenarioAttributes(frame: frame)
    }
    let service = AccessibilityWindowService(client: client, processIdentifier: 999)
    let coordinator = SwapCoordinator(
        authorization: TwoDisplaySwapScenarioAuthorizer(),
        displays: TwoDisplaySwapScenarioDisplayProvider(values: [displayB, displayA]),
        windowProvider: service,
        windowApplying: service
    )

    for invocation in 1...4 {
        #expect(coordinator.swap() == .success(attempted: 4, succeeded: 4))
        let expectedDisplay = invocation.isMultiple(of: 2) ? displayB : displayA
        for (token, expectedFrame) in zip(tokens, quarterFrames(on: expectedDisplay)) {
            expectApproximatelyEqual(currentFrame(for: token, in: client), expectedFrame)
        }
    }

    #expect(coordinator.lastDiagnostics == SwapDiagnostics(
        discovered: 4,
        eligible: 4,
        selected: 4,
        planned: 4,
        attempted: 4,
        succeeded: 4,
        failed: 0
    ))
}

@Test
@MainActor
func failedStatefulSwapReleasesGuardForTheFollowingInvocation() {
    let fixture = makeStatefulSwapFixture()
    fixture.client.failingPositionTokens = [fixture.ordinaryToken]

    #expect(fixture.coordinator.swap() == .partialFailure(attempted: 2, succeeded: 1, failed: 1))
    fixture.client.failingPositionTokens.removeAll()

    #expect(fixture.coordinator.swap() == .success(attempted: 2, succeeded: 2))
    #expect(currentFrame(for: fixture.zoomedToken, in: fixture.client) == fixture.zoomedInitialFrame)
    #expect(currentFrame(for: fixture.inactiveToken, in: fixture.client) == fixture.inactiveInitialFrame)
}
