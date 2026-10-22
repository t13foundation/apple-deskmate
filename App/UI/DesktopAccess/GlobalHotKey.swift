import AppKit
import Carbon.HIToolbox
import DeskMateCore

/// One system-wide keyboard shortcut, registered with Carbon's RegisterEventHotKey. That call needs no Accessibility
/// or Input Monitoring permission, works in the App Sandbox, and only reports the one combination that was registered:
/// no other key presses are seen. If another app or macOS already owns the combination the call fails and the result
/// says so; nothing is taken over silently.
@MainActor
final class GlobalHotKey {
    private static let signature: OSType = 0x444D_4B59 // 'DMKY'
    private static let identifier: UInt32 = 1
    /// The single live instance the C callback reports to.
    private static weak var active: GlobalHotKey?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?

    /// Registers `shortcut`, replacing any shortcut registered before.
    func register(_ shortcut: Shortcut) -> ShortcutRegistration {
        unregister()
        guard installHandlerIfNeeded() else { return .failed }
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            Self.carbonModifiers(for: shortcut.modifiers),
            id,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        switch status {
        case noErr:
            hotKey = reference
            Self.active = self
            return .registered
        case OSStatus(eventHotKeyExistsErr):
            return .inUse
        case OSStatus(eventHotKeyInvalidErr):
            return .invalid
        default:
            return .failed
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandlerIfNeeded() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var reference: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, &reference)
        guard status == noErr else { return false }
        handler = reference
        return true
    }

    static func carbonModifiers(for modifiers: Shortcut.Modifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    fileprivate static func pressed(signature: OSType, id: UInt32) {
        guard signature == Self.signature, id == Self.identifier else { return }
        active?.onPress?()
    }
}

/// Carbon calls this on the main thread. It carries no state; it only forwards the press.
private func hotKeyCallback(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let signature = hotKeyID.signature
    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { GlobalHotKey.pressed(signature: signature, id: id) }
    }
    return noErr
}
