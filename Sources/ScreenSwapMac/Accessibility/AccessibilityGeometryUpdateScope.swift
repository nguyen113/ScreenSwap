import Foundation

@MainActor
enum AccessibilityGeometryUpdateScope {
    static func perform(
        assistiveTechnologyActive: Bool,
        readEnhancedUI: () -> Bool?,
        writeEnhancedUI: (Bool) -> Bool,
        updates: () -> WindowApplyResult
    ) -> WindowApplyResult {
        guard !assistiveTechnologyActive, readEnhancedUI() == true,
              writeEnhancedUI(false) else { return updates() }
        defer { _ = writeEnhancedUI(true) }
        return updates()
    }
}
