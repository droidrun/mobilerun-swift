// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol

package enum ScrollInput {
    /// UIKit translation follows the content, so positive translation produces positive ticks.
    package static let ticksPerPoint = 0.01

    package static func route(at point: CGPoint, geometry: InputGeometry, h: Double, v: Double, buttons: Int) -> Data? {
        guard let mapped = geometry.map(point) else { return nil }
        return ControlMessages.scroll(videoWidth: geometry.videoWidth, videoHeight: geometry.videoHeight,
            x: mapped.x, y: mapped.y, hscrollTicks: h, vscrollTicks: v, buttons: buttons)
    }
}
