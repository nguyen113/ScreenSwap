import Carbon
import Foundation

@MainActor
public protocol GlobalHotKeyServicing: AnyObject {
    func register(_ shortcut: HotKeyShortcut, action: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

/// Public Carbon registration is used because AppKit has no global shortcut
/// API. It owns no swap logic; callers supply the same action as a left click.
@MainActor
public final class GlobalHotKeyService: GlobalHotKeyServicing {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (@MainActor () -> Void)?
    private static let signature: OSType = 0x53535750 // SSWP

    public init() {}
    public func register(_ shortcut: HotKeyShortcut, action: @escaping @MainActor () -> Void) -> Bool {
        unregister(); self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        guard InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let service = Unmanaged<GlobalHotKeyService>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x53535750 else { return noErr }
            Task { @MainActor in service.action?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return false }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            unregister()
            return false
        }
        return true
    }

    public func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        action = nil
    }
}
