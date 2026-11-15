// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol

package struct InputModifiers: OptionSet, Sendable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }
    package static let shift = Self(rawValue: 1)
    package static let control = Self(rawValue: 2)
    package static let alternate = Self(rawValue: 4)
    package static let command = Self(rawValue: 8)
    package static let capsLock = Self(rawValue: 16)
    package var isShortcut: Bool { !intersection([.control, .command]).isEmpty }
}

package enum KeyInput {
    private static let controlCodes: Set<String> = Set([
        "Backspace", "Delete", "Enter", "Tab", "Escape", "Home", "End", "PageUp", "PageDown", "Insert",
        "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "ShiftLeft", "ShiftRight", "ControlLeft",
        "ControlRight", "AltLeft", "AltRight", "MetaLeft", "MetaRight", "NumpadEnter",
    ] + (1...12).map { "F\($0)" })

    /// Clipboard is read lazily, only for the paste shortcut. The S1 map owns Android keycodes.
    package static func route(
        usage: Int, text: String, charactersIgnoringModifiers: String? = nil,
        down: Bool, modifiers: InputModifiers,
        clipboard: () -> String?
    ) -> [Data] {
        let code = HIDCode.values[usage] ?? "Unknown"
        // Native control keys can produce CR/TAB rather than browser named key values.
        let nativeText = nativeKey(code: code, text: text)
        return route(code: code, text: nativeText, charactersIgnoringModifiers: charactersIgnoringModifiers,
                     down: down, modifiers: modifiers, clipboard: clipboard)
    }

    package static func route(
        code: String, text: String, charactersIgnoringModifiers: String? = nil,
        down: Bool, modifiers: InputModifiers, clipboard: () -> String?
    ) -> [Data] {
        let keycode = KeyboardCode.values[code]
        let shortcut = modifiers.isShortcut
        let shortcutText = charactersIgnoringModifiers ?? text
        if down && shortcut && shortcutText.lowercased() == "v" {
            guard let text = clipboard(), !text.isEmpty else { return [] }
            return [ControlMessages.setClipboard(text: text, paste: true)]
        }
        if down && shortcut && shortcutText.lowercased() == "m" { return press(AndroidKey.menu) }
        var meta = 0
        let letter = code.hasPrefix("Key") && code.count == 4
        let shifted = modifiers.contains(.shift) != (letter && modifiers.contains(.capsLock))
        if shifted { meta |= AndroidKey.metaShiftOn }
        if modifiers.contains(.control) { meta |= AndroidKey.metaCtrlOn }
        if modifiers.contains(.alternate) { meta |= AndroidKey.metaAltOn }
        if modifiers.contains(.command) { meta |= AndroidKey.metaMetaOn }
        if isControlKey(text) || shortcut {
            guard let keycode else { return [] }
            return [ControlMessages.keycode(action: down ? AndroidKey.actionDown : AndroidKey.actionUp,
                                            keycode: keycode, metaState: meta)]
        }
        // Preserve one extended grapheme without normalization (UAX #29).
        if text.utf16.count == 1 || (text.count == 1 && !hasControlScalar(text)) { return down ? [ControlMessages.text(text)] : [] }
        if let keycode {
            return [ControlMessages.keycode(action: down ? AndroidKey.actionDown : AndroidKey.actionUp,
                                            keycode: keycode, metaState: meta)]
        }
        return []
    }

    /// UIKit produces CR/TAB for physical controls; abstract vectors already use named keys.
    package static func nativeKey(code: String, text: String) -> String {
        controlCodes.contains(code) ? (code == "NumpadEnter" ? "Enter" : code) : text
    }

    private static func isControlKey(_ key: String) -> Bool {
        controlCodes.contains(key) || key.hasPrefix("Shift") || key.hasPrefix("Control")
            || key.hasPrefix("Alt") || key.hasPrefix("Meta") || key.hasPrefix("Arrow")
            || (key.hasPrefix("F") && key.utf16.count <= 3)
    }

    package static func press(_ keycode: Int) -> [Data] {
        [ControlMessages.keycode(action: AndroidKey.actionDown, keycode: keycode),
         ControlMessages.keycode(action: AndroidKey.actionUp, keycode: keycode)]
    }

    private static func hasControlScalar(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    package static func committedText(_ text: String) -> [Data] {
        var packets: [Data] = []
        var pending = ""
        for character in text {
            if hasControlScalar(String(character)) {
                let key: Int?
                switch character {
                case "\n", "\r", "\r\n": key = AndroidKey.enter
                case "\t": key = AndroidKey.keycodeTab
                default: key = nil
                }
                if let key {
                    if !pending.isEmpty { packets.append(ControlMessages.text(pending)) }
                    pending = ""
                    packets += press(key)
                }
            } else { pending.append(character) }
        }
        if !pending.isEmpty { packets.append(ControlMessages.text(pending)) }
        return packets
    }
}

/// Records only emitted DOWNs, so changed produced text and shortcuts never create orphan UPs.
package struct KeyInputState {
    private var pressed: Set<String> = []
    package init() {}

    package mutating func route(
        code: String, text: String, down: Bool, modifiers: InputModifiers,
        clipboard: () -> String?
    ) -> [Data] {
        if !down {
            guard pressed.remove(code) != nil else { return [] }
            // Empty text takes the mapped fallback path for every recorded physical code.
            return KeyInput.route(code: code, text: "", down: false, modifiers: modifiers, clipboard: clipboard)
        }
        let packets = KeyInput.route(code: code, text: text, down: true, modifiers: modifiers, clipboard: clipboard)
        if packets.count == 1, packets[0].first == 0, packets[0][1] == 0 { pressed.insert(code) }
        return packets
    }
}
