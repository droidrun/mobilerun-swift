// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol

/// An inbound-video sample. Missing fields are nil; rates require two increasing reports.
/// Created by the SDK with no public initializer, allowing new fields without breaking callers.
public struct StreamStats: Sendable, Equatable {
    /// Decoded frames per second, instantaneous or calculated from counter deltas.
    public let fps: Double?
    /// Decoded frame width in pixels, before rotation.
    public let width: Int?
    /// Decoded frame height in pixels, before rotation.
    public let height: Int?
    /// Video MIME type, for example video/H264.
    public let codec: String?
    /// Received video payload kilobits per second, excluding transport overhead.
    public let bitrateKbps: Double?
    /// Current round-trip time of the selected ICE candidate pair, in milliseconds.
    public let rttMs: Double?
    /// Jitter-buffer delay per emitted frame during this sample, in milliseconds.
    public let jitterBufferDelayMs: Double?
    /// Cumulative lost packets, which can decrease when late packets arrive.
    public let packetsLost: Int64?
    /// Cumulative dropped frames.
    public let framesDropped: Int64?
    /// Cumulative freezes, when available.
    public let freezeCount: Int64?
    /// Decode time per decoded frame during this sample, in milliseconds.
    public let decodeTimeMs: Double?
    /// Selected local candidate: host, srflx, prflx, or relay.
    public let localCandidateType: String?
    /// Selected remote candidate: host, srflx, prflx, or relay.
    public let remoteCandidateType: String?
    /// Time from connection-attempt creation to the first decoded video frame, in milliseconds.
    public let timeToFirstFrameMs: Double?


}

/// Primitive projection of an RTCStats report; addresses and credentials never enter samples.
package struct StatsRecord: Sendable, Decodable {
    package let id: String
    package let type: String
    package let timestampUs: Double
    package let values: [String: MobilerunProtocol.JSONValue]

    package init(id: String, type: String, timestampUs: Double, values: [String: MobilerunProtocol.JSONValue]) {
        self.id = id
        self.type = type
        self.timestampUs = timestampUs
        self.values = values
    }

    func number(_ key: String) -> Double? {
        guard case .number(let value) = values[key], value.isFinite else { return nil }
        return value
    }
    func text(_ key: String) -> String? {
        guard case .string(let value) = values[key] else { return nil }
        return value
    }
    func integer<T: FixedWidthInteger>(_ key: String, as: T.Type) -> T? {
        number(key).flatMap { T(exactly: $0) }
    }
}

/// One parser per sampling cycle. W3C WebRTC Stats counters are cumulative, timestamps microseconds.
package struct StreamStatsParser {
    private var previous: StatsRecord?
    package init() {}

    package mutating func parse(_ records: [StatsRecord], firstFrameMs: Double?) -> StreamStats {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let video = records.first { $0.type == "inbound-rtp" && ($0.text("kind") ?? $0.text("mediaType")) == "video" }
        let old = previous.flatMap { old in
            video.flatMap { $0.id == old.id && $0.timestampUs > old.timestampUs ? old : nil }
        }
        previous = video
        func delta(_ key: String) -> Double? {
            guard let next = video?.number(key), let before = old?.number(key), next >= before else { return nil }
            return next - before
        }
        func perFrame(_ total: String, _ count: String) -> Double? {
            guard let frames = delta(count), frames > 0, let duration = delta(total) else { return nil }
            return duration * 1000 / frames
        }
        let seconds = video.flatMap { video in old.map { (video.timestampUs - $0.timestampUs) / 1_000_000 } }
        let transport = video?.text("transportId").flatMap { byID[$0] }
            ?? records.first { $0.type == "transport" && $0.text("selectedCandidatePairId") != nil }
        let pair = transport?.text("selectedCandidatePairId").flatMap { byID[$0] }
            ?? records.first { $0.type == "candidate-pair" && $0.values["selected"] == .bool(true) }
        func candidate(_ key: String) -> String? {
            guard let id = pair?.text(key), let type = byID[id]?.text("candidateType"),
                  ["host", "srflx", "prflx", "relay"].contains(type) else { return nil }
            return type
        }
        return StreamStats(
            fps: video?.number("framesPerSecond") ?? seconds.flatMap { seconds in delta("framesDecoded").map { $0 / seconds } },
            width: video?.integer("frameWidth", as: Int.self), height: video?.integer("frameHeight", as: Int.self),
            codec: video?.text("codecId").flatMap { byID[$0]?.text("mimeType") },
            bitrateKbps: seconds.flatMap { seconds in delta("bytesReceived").map { $0 * 8 / (seconds * 1000) } },
            rttMs: pair?.number("currentRoundTripTime").map { $0 * 1000 },
            jitterBufferDelayMs: perFrame("jitterBufferDelay", "jitterBufferEmittedCount"),
            packetsLost: video?.integer("packetsLost", as: Int64.self),
            framesDropped: video?.integer("framesDropped", as: Int64.self),
            freezeCount: video?.integer("freezeCount", as: Int64.self),
            decodeTimeMs: perFrame("totalDecodeTime", "framesDecoded"),
            localCandidateType: candidate("localCandidateId"), remoteCandidateType: candidate("remoteCandidateId"),
            timeToFirstFrameMs: firstFrameMs)
    }
}
