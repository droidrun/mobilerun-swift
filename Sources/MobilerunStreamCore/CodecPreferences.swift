// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

/// Shared MIME/name normalization for preference ordering and decoder fallback.
package enum CodecPreferences {
    private static let publishH264Profiles: Set<String> = ["42e0", "42c0", "4d00", "640c"]
    package static func supportsPublishH264Profile(_ value: String?) -> Bool {
        guard let profile = value?.lowercased(), profile.count == 6,
              publishH264Profiles.contains(String(profile.prefix(4))),
              let maximumLevel = Int(profile.suffix(2), radix: 16) else { return false }
        return maximumLevel >= 0x1f
    }

    package static func family(_ name: String) -> String {
        let subtype = name.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        switch subtype {
        case "hevc": return "h265"
        case "avc": return "h264"
        default: return subtype.hasPrefix("flexfec") ? "flexfec" : subtype
        }
    }

    package static func ordered<T>(_ codecs: [T], h264Only: Bool, name: (T) -> String) -> [T]? {
        let hasHEVC = codecs.contains { family(name($0)) == "h265" }
        let result: [T]
        if h264Only || !hasHEVC {
            result = codecs.filter {
                let kind = family(name($0))
                return kind == "h264" || auxiliary.contains(kind)
            }
        } else {
            let priorities = ["vp9": 1, "h265": 2, "h264": 3]
            result = codecs.enumerated().sorted {
                let left = priorities[family(name($0.element))] ?? 4
                let right = priorities[family(name($1.element))] ?? 4
                return (left, $0.offset) < (right, $1.offset)
            }.map(\.element)
        }
        return result.contains { !auxiliary.contains(family(name($0))) } ? result : nil
    }

    private static let auxiliary: Set<String> = ["rtx", "red", "ulpfec", "flexfec"]
}
