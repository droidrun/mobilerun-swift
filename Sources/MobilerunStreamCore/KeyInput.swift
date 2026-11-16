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

/// Owns keycode DOWN/UP balance; text and clipboard injection never acquire a pressed code.
package struct KeyInputState {
    private var pressed: Set<String> = []
    package init() {}

    private static let controlCodes: Set<String> = Set([
        "Backspace", "Delete", "Enter", "Tab", "Escape", "Home", "End", "PageUp", "PageDown", "Insert",
        "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "ShiftLeft", "ShiftRight", "ControlLeft",
        "ControlRight", "AltLeft", "AltRight", "MetaLeft", "MetaRight", "NumpadEnter",
    ] + (1...12).map { "F\($0)" })

    package mutating func route(
        code: String, text: String,
        down: Bool, modifiers: InputModifiers, clipboard: () -> String?
    ) -> [Data] {
        if !down {
            guard pressed.remove(code) != nil else { return [] }
            return keycodePacket(code: code, down: false, modifiers: modifiers)
        }
        // UIKit produces control characters for physical controls; vectors use named keys.
        let text = Self.controlCodes.contains(code) ? code : text
        let keycode = KeyboardCode.values[code]
        let shortcut = modifiers.isShortcut
        if shortcut && text.lowercased() == "v" {
            guard let text = clipboard(), !text.isEmpty else { return [] }
            return [ControlMessages.setClipboard(text: text, paste: true)]
        }
        if shortcut && text.lowercased() == "m" { return KeyInput.press(AndroidKey.menu) }
        if Self.isControlKey(text) || shortcut {
            guard keycode != nil else { return [] }
            pressed.insert(code)
            return keycodePacket(code: code, down: true, modifiers: modifiers)
        }
        // Preserve one extended grapheme without normalization (UAX #29).
        if text.utf16.count == 1 || (text.count == 1 && !KeyInput.hasControlScalar(text)) {
            return [ControlMessages.text(text)]
        }
        guard keycode != nil else { return [] }
        pressed.insert(code)
        return keycodePacket(code: code, down: true, modifiers: modifiers)
    }

    private func keycodePacket(code: String, down: Bool, modifiers: InputModifiers) -> [Data] {
        guard let keycode = KeyboardCode.values[code] else { return [] }
        var meta = 0
        let letter = code.hasPrefix("Key") && code.count == 4
        let shifted = modifiers.contains(.shift) != (letter && modifiers.contains(.capsLock))
        if shifted { meta |= AndroidKey.metaShiftOn }
        if modifiers.contains(.control) { meta |= AndroidKey.metaCtrlOn }
        if modifiers.contains(.alternate) { meta |= AndroidKey.metaAltOn }
        if modifiers.contains(.command) { meta |= AndroidKey.metaMetaOn }
        return [ControlMessages.keycode(action: down ? AndroidKey.actionDown : AndroidKey.actionUp,
                                        keycode: keycode, metaState: meta)]
    }

    private static func isControlKey(_ key: String) -> Bool {
        controlCodes.contains(key) || key.hasPrefix("Shift") || key.hasPrefix("Control")
            || key.hasPrefix("Alt") || key.hasPrefix("Meta") || key.hasPrefix("Arrow")
            || (key.hasPrefix("F") && key.utf16.count <= 3)
    }

}

package enum KeyInput {
    package static func press(_ keycode: Int) -> [Data] {
        [ControlMessages.keycode(action: AndroidKey.actionDown, keycode: keycode),
         ControlMessages.keycode(action: AndroidKey.actionUp, keycode: keycode)]
    }

    fileprivate static func hasControlScalar(_ text: String) -> Bool {
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
