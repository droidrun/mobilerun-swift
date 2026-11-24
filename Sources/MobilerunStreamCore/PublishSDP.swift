// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Checks generated upstream reservations without modifying SDP.
package enum PublishSDP {
    package static func hasReservation(_ sdp: String, kind: PublishKind) -> Bool {
        sdp.components(separatedBy: "m=").dropFirst().contains { section in
            let lines = section.components(separatedBy: .newlines)
            let header = lines.first?.split(separator: " ") ?? []
            return header.first == Substring(kind.rawValue) && header.count > 1 && header[1] != "0"
                && lines.contains("a=sendonly") && lines.contains(where: { $0.hasPrefix("a=ssrc:") })
        }
    }
}
