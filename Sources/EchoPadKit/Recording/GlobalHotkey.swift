import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut through Carbon's `RegisterEventHotKey`. Unlike an
/// event tap it needs no Accessibility permission, which keeps EchoPad's setup short.
@MainActor
public final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    private static let SIGNATURE: OSType = 0x4543_4850 // 'ECHP'

    public init() {}

    /// Registers `hotkey`, replacing any previous one. Returns false when another app owns it.
    @discardableResult
    public func register(_ hotkey: Hotkey, action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotkey.action?() }
            return noErr
        }, 1, &eventType, context, &handlerRef)

        let id = EventHotKeyID(signature: Self.SIGNATURE, id: 1)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}

/// Human readable shortcut text like ⌃⌥⌘E.
public enum HotkeyLabel {
    public static func describe(_ hotkey: Hotkey) -> String {
        var text = ""
        if hotkey.modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if hotkey.modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if hotkey.modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if hotkey.modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName(UInt16(hotkey.keyCode))
    }

    static func keyName(_ code: UInt16) -> String {
        let special: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        ]
        if let name = special[code] { return name }
        let letters: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
            22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
            32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        ]
        return letters[code] ?? "Key \(code)"
    }

    /// Carbon modifiers from AppKit flags.
    public static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}
