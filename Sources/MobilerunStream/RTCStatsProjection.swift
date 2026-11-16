// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import Foundation
import MobilerunProtocol
import MobilerunStreamCore

/// Pure projection of RTCStatistics fields. Its native initializer is unavailable, so tests
/// supply the same Foundation values directly rather than constructing a fake WebRTC object.
func projectStatistics(id: String, type: String, timestampUs: Double,
                       values: [String: NSObject]) -> StatsRecord? {
    switch type {
    case "inbound-rtp", "codec", "transport", "candidate-pair", "local-candidate", "remote-candidate": break
    default: return nil
    }
    var projected: [String: JSONValue] = [:]
    for (key, value) in values {
        if let number = value as? NSNumber {
            projected[key] = CFGetTypeID(number) == CFBooleanGetTypeID()
                ? .bool(number.boolValue) : .number(number.doubleValue)
        } else if let text = value as? String {
            projected[key] = .string(text)
        }
    }
    return StatsRecord(id: id, type: type, timestampUs: timestampUs, values: projected)
}
#endif
