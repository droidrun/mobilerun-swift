// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

/// Options applied to each newly created peer connection.
public struct StreamConfig: Sendable {
    public enum VideoCodec: Sendable { case automatic, h264Only }
    /// Device audio is muted by default.
    public var muted: Bool
    /// Automatic prefers VP9, H.265, then H.264; without an H.265 decoder it offers H.264 only.
    public var videoCodec: VideoCodec
    public init(muted: Bool = true, videoCodec: VideoCodec = .automatic) {
        self.muted = muted
        self.videoCodec = videoCodec
    }
}
