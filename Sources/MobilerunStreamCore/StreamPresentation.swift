// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

/// Shared default chrome/input mapping. Backend authorization remains authoritative.
package struct StreamPresentation {
    package let canControl: Bool
    package let showsPlaceholder: Bool
    package let showsUnavailable: Bool
    package init(status: StreamStatus, hasControl: Bool, isClosed: Bool = false) {
        canControl = hasControl && !isClosed && status != .unavailable
        showsUnavailable = status == .unavailable
        switch status {
        case .connecting, .reconnecting: showsPlaceholder = true
        default: showsPlaceholder = false
        }
    }
}
