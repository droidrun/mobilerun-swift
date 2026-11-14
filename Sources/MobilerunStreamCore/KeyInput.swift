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
        let code = HIDCode.values[usage]
        let keycode = code.flatMap { KeyboardCode.values[$0] }
        let shortcut = modifiers.isShortcut
        let shortcutText = charactersIgnoringModifiers ?? text
        if down && shortcut && shortcutText.lowercased() == "v" {
            guard let text = clipboard(), !text.isEmpty else { return [] }
            return [ControlMessages.setClipboard(text: text, paste: true)]
        }
        if down && shortcut && shortcutText.lowercased() == "m" { return press(AndroidKey.menu) }
        var meta = 0
        let letter = code?.hasPrefix("Key") == true
        let shifted = modifiers.contains(.shift) != (letter && modifiers.contains(.capsLock))
        if shifted { meta |= AndroidKey.metaShiftOn }
        if modifiers.contains(.control) { meta |= AndroidKey.metaCtrlOn }
        if modifiers.contains(.alternate) { meta |= AndroidKey.metaAltOn }
        if modifiers.contains(.command) { meta |= AndroidKey.metaMetaOn }
        if code.map({ controlCodes.contains($0) }) == true || shortcut {
            guard let keycode else { return [] }
            return [ControlMessages.keycode(action: down ? AndroidKey.actionDown : AndroidKey.actionUp,
                                            keycode: keycode, metaState: meta)]
        }
        // React uses JavaScript string length: one UTF-16 code unit, not one Swift grapheme.
        if down && text.utf16.count == 1 { return [ControlMessages.text(text)] }
        if down, let keycode {
            return [ControlMessages.keycode(action: AndroidKey.actionDown, keycode: keycode, metaState: meta)]
        }
        return []
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
                if !pending.isEmpty { packets.append(ControlMessages.text(pending)) }
                pending = ""
                switch character {
                case "\n", "\r", "\r\n": packets += press(AndroidKey.enter)
                case "\t": packets += press(AndroidKey.keycodeTab)
                default: break
                }
            } else { pending.append(character) }
        }
        if !pending.isEmpty { packets.append(ControlMessages.text(pending)) }
        return packets
    }
}
