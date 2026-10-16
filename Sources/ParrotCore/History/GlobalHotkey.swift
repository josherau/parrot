import Carbon.HIToolbox

/// One global shortcut through Carbon's `RegisterEventHotKey`.
///
/// The system delivers only this exact combo, so it needs no Accessibility
/// grant and sees nothing else the user types. `HotkeyMonitor`'s tap stays
/// flagsChanged-only: a keyDown tap would see every key, passwords included.
@MainActor
final class GlobalHotkey {
    /// 'PRRT': marks Parrot's hotkeys in the application event target.
    private static let signature: OSType = 0x5052_5254
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?
    private var id: UInt32 = 0

    private(set) var combo: KeyCombo?

    /// Registers `combo`, replacing any combo registered before. Calls
    /// `onPress` on the main thread on each key-down. Returns false if the
    /// system refused it, for example because another app holds it.
    @discardableResult
    func register(_ combo: KeyCombo, onPress: @escaping () -> Void) -> Bool {
        unregister()
        Self.installHandler()
        let id = Self.nextID
        Self.nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            Log.warning("paste last: couldn't register \(combo.displayName) (status \(status)); another app may be using it")
            return false
        }
        self.ref = ref
        self.id = id
        self.combo = combo
        Self.handlers[id] = onPress
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
        ref = nil
        combo = nil
    }

    /// One handler for all of Parrot's hotkeys, dispatching by id.
    private static func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
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
            guard status == noErr, hotKeyID.signature == GlobalHotkey.signature else {
                return OSStatus(eventNotHandledErr)
            }
            // The application event target dispatches on the main thread.
            MainActor.assumeIsolated { GlobalHotkey.handlers[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = status == noErr
        if status != noErr { Log.warning("paste last: couldn't install the hotkey handler (status \(status))") }
    }
}
