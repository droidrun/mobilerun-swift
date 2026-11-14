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
}

package enum KeyInput {
    private static let controlCodes: Set<String> = Set([
        "Backspace", "Delete", "Enter", "Tab", "Escape", "Home", "End", "PageUp", "PageDown", "Insert",
        "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "ShiftLeft", "ShiftRight", "ControlLeft",
        "ControlRight", "AltLeft", "AltRight", "MetaLeft", "MetaRight", "NumpadEnter",
    ] + (1...12).map { "F\($0)" })

    /// Clipboard is read lazily, only for the paste shortcut. The S1 map owns Android keycodes.
    package static func route(
        usage: Int, text: String, down: Bool, modifiers: InputModifiers,
        clipboard: () -> String?
    ) -> [Data] {
        guard let code = HIDCode.values[usage], let keycode = KeyboardCode.values[code] else { return [] }
        let shortcut = !modifiers.intersection([.control, .command]).isEmpty
        if down && shortcut && text.lowercased() == "v" {
            guard let text = clipboard(), !text.isEmpty else { return [] }
            return [ControlMessages.setClipboard(text: text, paste: true)]
        }
        if down && shortcut && text.lowercased() == "m" { return press(AndroidKey.menu) }
        var meta = 0
        let letter = code.hasPrefix("Key")
        let shifted = modifiers.contains(.shift) != (letter && modifiers.contains(.capsLock))
        if shifted { meta |= AndroidKey.metaShiftOn }
        if modifiers.contains(.control) { meta |= AndroidKey.metaCtrlOn }
        if modifiers.contains(.alternate) { meta |= AndroidKey.metaAltOn }
        if modifiers.contains(.command) { meta |= AndroidKey.metaMetaOn }
        let controlCharacter = text.unicodeScalars.contains { $0.properties.generalCategory == .control }
        if controlCodes.contains(code) || shortcut || controlCharacter {
            return [ControlMessages.keycode(action: down ? AndroidKey.actionDown : AndroidKey.actionUp,
                                            keycode: keycode, metaState: meta)]
        }
        // React uses JavaScript string length: one UTF-16 code unit, not one Swift grapheme.
        if down && text.utf16.count == 1 { return [ControlMessages.text(text)] }
        if down {
            return [ControlMessages.keycode(action: AndroidKey.actionDown, keycode: keycode, metaState: meta)]
        }
        return []
    }

    package static func press(_ keycode: Int) -> [Data] {
        [ControlMessages.keycode(action: AndroidKey.actionDown, keycode: keycode),
         ControlMessages.keycode(action: AndroidKey.actionUp, keycode: keycode)]
    }

    package static func committedText(_ text: String) -> [Data] {
        var packets: [Data] = []
        var pending = ""
        for character in text {
            let newline = character == "\n" || character == "\r" || character == "\r\n"
            let control = character.unicodeScalars.contains { $0.properties.generalCategory == .control }
            if control {
                if !pending.isEmpty { packets.append(ControlMessages.text(pending)) }
                pending = ""
                if newline { packets += press(AndroidKey.enter) }
                else if character == "\t" { packets += press(AndroidKey.keycodeTab) }
            } else { pending.append(character) }
        }
        if !pending.isEmpty { packets.append(ControlMessages.text(pending)) }
        return packets
    }
}
