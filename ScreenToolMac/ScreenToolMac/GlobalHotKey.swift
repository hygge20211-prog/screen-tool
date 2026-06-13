import Carbon.HIToolbox

/// Registers a system-wide hotkey via Carbon `RegisterEventHotKey`.
/// Works regardless of which app is frontmost, and needs no extra permission.
final class GlobalHotKey {

    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Called on the main run loop when the hotkey is pressed.
    var onFire: (() -> Void)?

    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `kVK_ANSI_5` (0x17)
    ///   - modifiers: Carbon modifier mask, e.g. `cmdKey | controlKey`
    init(keyCode: UInt32, modifiers: UInt32) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData = userData else { return noErr }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            me.onFire?()
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        var hotKeyID = EventHotKeyID(signature: OSType(0x53435354) /* 'SCST' */, id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref = ref { UnregisterEventHotKey(ref) }
        if let handlerRef = handlerRef { RemoveEventHandler(handlerRef) }
    }
}
