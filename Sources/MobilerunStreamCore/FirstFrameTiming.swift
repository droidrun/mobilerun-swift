// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One clock per connection attempt, stamped directly by its first decoded-frame callback.
package final class FirstFrameTiming: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt: TimeInterval
    private var first: Double?
    package init(startedAt: TimeInterval) { self.startedAt = startedAt }
    package var value: Double? { lock.withLock { first } }
    package func stamp(at time: TimeInterval) {
        lock.withLock {
            if first == nil { first = max(0, time - startedAt) * 1000 }
        }
    }
}
