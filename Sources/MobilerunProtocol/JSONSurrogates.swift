// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation

// JSON permits lone UTF-16 surrogate escapes, which Foundation rejects. Decode surrogate escapes
// into code units first: Swift's UTF-16 decoder preserves pairs and repairs each lone unit to U+FFFD.
// Other escapes stay escaped so quotes, backslashes and control characters cannot change JSON syntax.
func repairingJSONSurrogates(_ data: Data) -> Data {
    let units = Array(String(decoding: data, as: UTF8.self).utf16)
    var output: [UInt16] = []
    output.reserveCapacity(units.count)
    var inString = false
    var index = 0
    while index < units.count {
        let unit = units[index]
        if inString, unit == 0x5c, index + 1 < units.count {
            if units[index + 1] == 0x75, index + 5 < units.count,
               let escaped = UInt16(String(decoding: units[(index + 2)...(index + 5)], as: UTF16.self),
                                    radix: 16),
               (0xd800...0xdfff).contains(escaped) {
                output.append(escaped)
                index += 6
            } else {
                output.append(contentsOf: units[index...(index + 1)])
                index += 2
            }
        } else {
            if unit == 0x22 { inString.toggle() }
            output.append(unit)
            index += 1
        }
    }
    return Data(String(decoding: output, as: UTF16.self).utf8)
}
