import AppKit
import Foundation
import HotKey
import Logging

struct GlobalCaptureHotKeyConfiguration: Equatable {
    var enabled: Bool
    var keyCode: UInt32?
    var modifiers: UInt32

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(modifiers))
    }
}

final class GlobalCaptureHotKeyManager {
    static let defaultsKeyCodeKey = "kiririn.capture.hotkey.key_code"
    static let defaultsModifiersKey = "kiririn.capture.hotkey.modifiers"

    private static let allowedModifierFlags: NSEvent.ModifierFlags = [
        .command, .option, .control, .shift,
    ]
    private static let modifierOnlyKeyCodes: Set<UInt16> = [
        54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    ]

    private let logger = Logger(label: "GlobalCaptureHotKeyManager")
    private let onTrigger: () -> Void
    private var hotKey: HotKey?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        reloadFromDefaults()
    }

    deinit {
        hotKey = nil
    }

    func reloadFromDefaults(_ defaults: UserDefaults = .standard) {
        let configuration = Self.loadFromDefaults(defaults)
        apply(configuration: configuration)
    }

    func apply(configuration: GlobalCaptureHotKeyConfiguration) {
        hotKey = nil

        guard configuration.enabled,
            let keyCode = configuration.keyCode,
            keyCode <= UInt32(UInt16.max)
        else {
            return
        }

        let normalizedFlags = Self.normalizedModifierFlags(configuration.modifierFlags)
        guard !Self.isModifierOnlyKey(UInt16(keyCode)) else {
            return
        }

        logger.info(
            "registering global capture hotkey: \(Self.shortcutDisplayString(keyCode: UInt16(keyCode), modifiers: normalizedFlags))"
        )

        let keyCombo = KeyCombo(
            carbonKeyCode: keyCode,
            carbonModifiers: normalizedFlags.carbonFlags
        )
        let newHotKey = HotKey(keyCombo: keyCombo)
        newHotKey.keyDownHandler = { [weak self] in
            self?.logger.info("global capture hotkey triggered")
            self?.onTrigger()
        }
        hotKey = newHotKey
    }

    static func loadFromDefaults(_ defaults: UserDefaults = .standard)
        -> GlobalCaptureHotKeyConfiguration
    {
        let keyCodeValue = defaults.object(forKey: defaultsKeyCodeKey) as? Int
        let keyCode = keyCodeValue.flatMap { $0 >= 0 ? UInt32($0) : nil }
        let modifiers = UInt32(defaults.integer(forKey: defaultsModifiersKey))
        let enabled = keyCode != nil
        return GlobalCaptureHotKeyConfiguration(
            enabled: enabled, keyCode: keyCode, modifiers: modifiers)
    }

    static func normalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(allowedModifierFlags)
    }

    static func isModifierOnlyKey(_ keyCode: UInt16) -> Bool {
        modifierOnlyKeyCodes.contains(keyCode)
    }

    static func shortcutDisplayString(keyCode: UInt16?, modifiers: NSEvent.ModifierFlags)
        -> String
    {
        guard let keyCode else { return "未設定" }

        let normalized = normalizedModifierFlags(modifiers)
        let symbols: [String] = [
            normalized.contains(.control) ? "⌃" : "",
            normalized.contains(.option) ? "⌥" : "",
            normalized.contains(.shift) ? "⇧" : "",
            normalized.contains(.command) ? "⌘" : "",
        ]

        let keyName = keyDisplayName(for: keyCode)
        return symbols.joined() + keyName
    }

    private static func keyDisplayName(for keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
            20: "3",
            21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]",
            31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K",
            41: ";",
            42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 49: "Space", 50: "`",
            51: "Delete",
            53: "Esc", 65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/", 76: "Enter", 78: "-",
            81: "=",
            82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8",
            92: "9",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
            105: "F13", 106: "F16",
            107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home",
            116: "PageUp", 117: "ForwardDelete",
            118: "F4", 119: "End", 120: "F2", 121: "PageDown", 122: "F1", 123: "←", 124: "→",
            125: "↓", 126: "↑",
        ]

        if let value = map[keyCode] {
            return value
        }

        return "KeyCode \(keyCode)"
    }
}
