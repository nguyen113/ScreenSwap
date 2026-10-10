import Carbon
import Foundation

@MainActor
public protocol GlobalHotKeyServicing: AnyObject {
    func register(_ shortcut: HotKeyShortcut, action: @escaping @MainActor () -> Void) -> Bool
    func registerMove(_ shortcut: HotKeyShortcut, action: @escaping @MainActor () -> Void) -> Bool
    func registerCallReturn(_ shortcut: HotKeyShortcut, action: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

private enum HotKeyCommand: UInt32 {
    case swap = 1
    case move = 2
    case callReturn = 3
}

/// Public Carbon registration is used because AppKit has no global shortcut
/// API. One handler dispatches independent commands by hot-key ID.
@MainActor
public final class GlobalHotKeyService: GlobalHotKeyServicing {
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private static let signature: OSType = 0x53535750 // SSWP

    public init() {}
    public func register(_ shortcut: HotKeyShortcut, action: @escaping @MainActor () -> Void) -> Bool {
        register(shortcut, command: .swap, action: action)
    }

    public func registerMove(_ shortcut: HotKeyShortcut, action: @escaping @MainActor () -> Void) -> Bool {
        register(shortcut, command: .move, action: action)
    }

    public func registerCallReturn(_ shortcut: HotKeyShortcut, action: @escaping @MainActor () -> Void) -> Bool {
        register(shortcut, command: .callReturn, action: action)
    }

    private func register(_ shortcut: HotKeyShortcut, command: HotKeyCommand, action: @escaping @MainActor () -> Void) -> Bool {
        if let old = hotKeys.removeValue(forKey: command.rawValue) { UnregisterEventHotKey(old) }
        actions.removeValue(forKey: command.rawValue)
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        if handler == nil {
            guard InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let event, let userData else { return noErr }
                let service = Unmanaged<GlobalHotKeyService>.fromOpaque(userData).takeUnretainedValue()
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                      id.signature == 0x53535750 else { return noErr }
                let commandID = id.id
                Task { @MainActor in service.actions[commandID]?() }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return false }
        }
        let id = EventHotKeyID(signature: Self.signature, id: command.rawValue)
        var hotKey: EventHotKeyRef?
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr,
              let hotKey else {
            return false
        }
        hotKeys[command.rawValue] = hotKey
        actions[command.rawValue] = action
        return true
    }

    public func unregister() {
        for hotKey in hotKeys.values { UnregisterEventHotKey(hotKey) }
        hotKeys.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        actions.removeAll()
    }
}
