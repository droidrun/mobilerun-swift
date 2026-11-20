// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Retry budgets and exponential backoff shared by the streaming clients.
public enum ReconnectPolicy {
    /// Maximum scheduled retries before a failure declares the stream unavailable.
    public static let maxAttempts = 6
    /// Independent deadline for acquiring one socket key.
    package static let providerTimeoutMs = 10_000
    /// Whole-attempt watchdog; exceeds the combined signalling phase budgets.
    package static let connectTimeoutMs = 45_000
    /// Continuous connection duration that refills the retry budget.
    package static let stabilityMs = 30_000
    /// First retry delay before jitter.
    package static let baseDelayMs = 1_000
    /// Backoff cap before jitter.
    package static let maxDelayMs = 30_000

    /// Delay for the one-based attempt with ±25% jitter, rounded half toward positive infinity.
    /// Values below one count as one. Supply random in [0, 1); 0.5 disables jitter.
    package static func delayMs(attempt: Int, random: Double) -> Int {
        let exponent = max(1, attempt) - 1
        let base = min(Double(baseDelayMs) * pow(2, Double(exponent)), Double(maxDelayMs))
        return Int(floor(base * (0.75 + random * 0.5) + 0.5))
    }
}
