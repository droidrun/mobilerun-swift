// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

/// Signalling timing contract. All durations are in milliseconds.
public enum SignallingTiming {
    /// Budget for opening the signalling socket.
    public static let wsOpenTimeoutMs = 15_000
    /// Budget for receiving the initial RTC configuration.
    public static let rtcConfigTimeoutMs = 15_000
    /// Number of frame requests after the control channel opens.
    public static let requestFrameCount = 12
    /// Spacing between frame requests.
    public static let requestFrameIntervalMs = 125
    /// Keep-alive interval while visible and connected.
    public static let keepAliveIntervalMs = 10_000
    /// Grace period for non-terminal connection dips during credential refresh.
    public static let iceRestartGraceMs = 15_000
    /// Timeout for a pending screenshot request.
    public static let screenshotTimeoutMs = 30_000
}

/// A negotiated data channel specification, without a WebRTC dependency.
public struct DataChannelSpec: Sendable, Equatable {
    /// Channel name.
    public let label: String
    /// Negotiated channel identifier.
    public let id: Int
    /// Both peers create the channel explicitly.
    public let negotiated: Bool
    /// Whether messages must arrive in order.
    public let ordered: Bool
    /// Retransmit limit; nil means reliable delivery.
    public let maxRetransmits: Int?
}

/// The channel contract shared by all streaming clients.
public enum DataChannels {
    /// Reliable, ordered channel for binary controls except hover.
    public static let control = DataChannelSpec(label: "control", id: 1, negotiated: true,
                                               ordered: true, maxRetransmits: nil)
    /// Unordered hover channel; messages are dropped while it is not open.
    public static let hover = DataChannelSpec(label: "hover", id: 2, negotiated: true,
                                             ordered: false, maxRetransmits: 0)
}
