// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoreGraphics

/// Aspect-fit geometry in view points and upright (post-rotation) video pixels.
package struct InputGeometry: Equatable, Sendable {
    package let rect: CGRect
    package let videoWidth: Int
    package let videoHeight: Int

    package init?(bounds: CGRect, video: VideoSize?) {
        guard let video, video.width > 0, video.height > 0,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let swapped = video.rotation % 180 != 0
        videoWidth = swapped ? video.height : video.width
        videoHeight = swapped ? video.width : video.height
        let scale = min(bounds.width / Double(videoWidth), bounds.height / Double(videoHeight))
        let width = Double(videoWidth) * scale
        let height = Double(videoHeight) * scale
        rect = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                      width: width, height: height)
    }

    /// Inclusive edges match React. Letterbox points and non-finite input are ignored.
    package func map(_ point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= rect.minX, point.x <= rect.maxX,
              point.y >= rect.minY, point.y <= rect.maxY else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width * Double(videoWidth),
                          y: (point.y - rect.minY) / rect.height * Double(videoHeight))
    }
}
