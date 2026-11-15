// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol

func parsePaymentCardDetails(_ details: JSONValue) -> PaymentCardDetails? {
    guard case .object(let object) = details else { return nil }
    func string(_ key: String) -> String? {
        guard case .string(let value) = object[key], !value.isEmpty else { return nil }
        return value
    }
    guard let card = string("label") ?? string("credentialName"),
          let package = string("targetPackage") else { return nil }
    return PaymentCardDetails(card: card, targetPackage: package, targetHost: string("targetHost"))
}

func approvalExpiryMs(_ expiresAt: String) -> Double? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: expiresAt) ?? {
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: expiresAt)
    }()
    return date.map { $0.timeIntervalSince1970 * 1000 }
}

func formatRemaining(_ ms: Double) -> String {
    let total = Int(min(Double(Int.max / 2), max(0, ms.isFinite ? ceil(ms / 1000) : 0)))
    let h = total / 3600, m = total % 3600 / 60, s = total % 60
    if h > 0 { return "\(h)h \(m)m \(s)s" }
    return m > 0 ? "\(m)m \(s)s" : "\(s)s"
}

func remainingMs(expiresAt: String, nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Double {
    approvalExpiryMs(expiresAt).map { $0 - nowMs } ?? 0
}

/// Suppresses repeated announcements when the same error view is rebuilt or shown again.
struct ApprovalErrorAnnouncement {
    private var previous: String?
    mutating func update(_ text: String?) -> Bool {
        guard text != previous else { return false }
        previous = text
        return text != nil
    }
}
