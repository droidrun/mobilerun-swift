// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol

package func paymentCardFields(_ details: JSONValue) -> (card: String, package: String, host: String?)? {
    guard case .object(let object) = details else { return nil }
    func string(_ key: String) -> String? {
        guard case .string(let value) = object[key], !value.isEmpty else { return nil }
        return value
    }
    guard let card = string("label") ?? string("credentialName"),
          let package = string("targetPackage") else { return nil }
    return (card, package, string("targetHost"))
}

package func approvalRemainingMs(_ expiresAt: String, nowMs: Double) -> Double {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: expiresAt) ?? {
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: expiresAt)
    }()
    return date.map { $0.timeIntervalSince1970 * 1000 - nowMs } ?? 0
}

package func approvalFormattedRemaining(_ ms: Double) -> String {
    let total = Int(min(Double(Int.max / 2), max(0, ms.isFinite ? ceil(ms / 1000) : 0)))
    let h = total / 3600, m = total % 3600 / 60, s = total % 60
    if h > 0 { return "\(h)h \(m)m \(s)s" }
    return m > 0 ? "\(m)m \(s)s" : "\(s)s"
}

/// Ignores initial/replayed values; only real transitions wake a session.
package struct StreamWakeTransitions {
    private var foreground: Bool
    private var online: Bool?
    package init(foreground: Bool) { self.foreground = foreground }
    package mutating func setForeground(_ value: Bool) -> Bool {
        defer { foreground = value }
        return !foreground && value
    }
    package mutating func setOnline(_ value: Bool) -> Bool {
        defer { online = value }
        return online == false && value
    }
}
