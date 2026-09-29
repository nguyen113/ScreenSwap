import Foundation

/// Raw green-button state can describe native tiles as well as zoomed windows.
/// Capture once and use the semantic mode throughout apply and rollback.
enum CapturedPresentationMode: String, Sendable {
    case ordinary
    case windowedMaximized
    case nativeZoomed
    case nativeFullScreen

    static func classify(
        _ rawState: WindowPresentationState,
        fillsSourceVisibleFrame: Bool,
        retainedMaximizedIntent: Bool = false
    ) -> Self {
        if rawState.isFullScreen == true { return .nativeFullScreen }
        if rawState.isZoomed == true && fillsSourceVisibleFrame { return .nativeZoomed }
        if fillsSourceVisibleFrame || retainedMaximizedIntent { return .windowedMaximized }
        return .ordinary
    }
}
