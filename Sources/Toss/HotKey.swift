import Carbon.HIToolbox

/// One global shortcut through Carbon's RegisterEventHotKey, which needs no
/// Accessibility or Input Monitoring permission.
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var current: HotKey?

    init(action: @escaping () -> Void) {
        self.action = action
        HotKey.current = self
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { HotKey.current?.action() }
            return noErr
        }, 1, &type, nil, &handler)
    }

    /// Replaces the registered shortcut. Returns false if another app holds it.
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        let id = EventHotKeyID(signature: OSType(0x546F_7373), id: 1) // "Toss"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference)
        return status == noErr
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }
}
