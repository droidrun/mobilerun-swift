// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

package enum ScrollInput {
    package enum Unit { case pixel, line, page }
    /// Browser-style deltas. UIKit pan translation is negated before this conversion.
    package static func ticks(horizontal: Double, vertical: Double, unit: Unit) -> (Double, Double) {
        let scale: Double
        switch unit {
        case .pixel: scale = -0.01
        case .line: scale = -1
        case .page: scale = -3
        }
        return (horizontal * scale, vertical * scale)
    }
}
