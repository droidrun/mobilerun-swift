// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import MobilerunStreamCore

// Address-free projections of native getStats records. Values use W3C counter units.
private let recordedReports = #"""
[
 [
  {"id":"video","type":"inbound-rtp","timestampUs":1000000,"values":{"kind":"video","frameWidth":1080,"frameHeight":2400,"codecId":"codec","transportId":"transport","bytesReceived":1000,"framesDecoded":10,"totalDecodeTime":0.125,"jitterBufferDelay":0.125,"jitterBufferEmittedCount":10,"packetsLost":3,"framesDropped":1,"freezeCount":0}},
  {"id":"codec","type":"codec","timestampUs":1000000,"values":{"mimeType":"video/H264"}},
  {"id":"transport","type":"transport","timestampUs":1000000,"values":{"selectedCandidatePairId":"pair"}},
  {"id":"pair","type":"candidate-pair","timestampUs":1000000,"values":{"currentRoundTripTime":0.025,"localCandidateId":"local","remoteCandidateId":"remote"}},
  {"id":"local","type":"local-candidate","timestampUs":1000000,"values":{"candidateType":"host"}},
  {"id":"remote","type":"remote-candidate","timestampUs":1000000,"values":{"candidateType":"relay"}}
 ],
 [
  {"id":"video","type":"inbound-rtp","timestampUs":2000000,"values":{"kind":"video","frameWidth":1080,"frameHeight":2400,"codecId":"codec","transportId":"transport","bytesReceived":126000,"framesDecoded":60,"totalDecodeTime":0.25,"jitterBufferDelay":0.625,"jitterBufferEmittedCount":60,"packetsLost":2,"framesDropped":2,"freezeCount":1}},
  {"id":"codec","type":"codec","timestampUs":2000000,"values":{"mimeType":"video/H264"}},
  {"id":"transport","type":"transport","timestampUs":2000000,"values":{"selectedCandidatePairId":"pair"}},
  {"id":"pair","type":"candidate-pair","timestampUs":2000000,"values":{"currentRoundTripTime":0.03,"localCandidateId":"local","remoteCandidateId":"remote"}},
  {"id":"local","type":"local-candidate","timestampUs":2000000,"values":{"candidateType":"host"}},
  {"id":"remote","type":"remote-candidate","timestampUs":2000000,"values":{"candidateType":"relay"}}
 ]
]
"""#

private func reports() throws -> [[StatsRecord]] {
    try JSONDecoder().decode([[StatsRecord]].self, from: Data(recordedReports.utf8))
}

struct StreamStatsTests {
    @Test func recordedVideoUsesDeltasAndSelectedPair() throws {
        let records = try reports()
        var parser = StreamStatsParser()
        let first = parser.parse(records[0], firstFrameMs: 240)
        #expect(first.bitrateKbps == nil)
        #expect(first.decodeTimeMs == nil)
        #expect(first.jitterBufferDelayMs == nil)
        #expect(first.fps == nil)
        let stats = parser.parse(records[1], firstFrameMs: 240)
        #expect(stats == StreamStats(fps: 50, width: 1080, height: 2400, codec: "video/H264",
            bitrateKbps: 1000, rttMs: 30, jitterBufferDelayMs: 10, packetsLost: 2,
            framesDropped: 2, freezeCount: 1, decodeTimeMs: 2.5,
            localCandidateType: "host", remoteCandidateType: "relay", timeToFirstFrameMs: 240))
        #expect(stats.description.contains("remoteCandidateType"))
    }

    @Test func missingFieldsAreNil() {
        var parser = StreamStatsParser()
        #expect(parser.parse([], firstFrameMs: nil) == StreamStats(
            fps: nil, width: nil, height: nil, codec: nil, bitrateKbps: nil, rttMs: nil,
            jitterBufferDelayMs: nil, packetsLost: nil, framesDropped: nil, freezeCount: nil,
            decodeTimeMs: nil, localCandidateType: nil, remoteCandidateType: nil, timeToFirstFrameMs: nil))
    }

    @Test(arguments: ["duplicate", "backward", "reset", "replacement"])
    func invalidDeltasAreNil(scenario: String) throws {
        let records = try reports()
        var parser = StreamStatsParser()
        _ = parser.parse(records[0], firstFrameMs: 240)
        let record = records[1][0]
        let timestamp: Double = scenario == "duplicate" ? 1_000_000 : scenario == "backward" ? 500_000 : 2_000_000
        let changed = StatsRecord(id: scenario == "replacement" ? "new-video" : record.id,
            type: record.type, timestampUs: timestamp,
            values: scenario == "reset" ? records[0][0].values.mapValues { _ in .number(0) }
                .merging(["kind": .string("video")]) { _, new in new } : record.values)
        let stats = parser.parse([changed], firstFrameMs: nil)
        #expect(stats.bitrateKbps == nil)
        #expect(stats.fps == nil)
        #expect(stats.decodeTimeMs == nil)
        #expect(stats.jitterBufferDelayMs == nil)
    }

    @Test func legacyVideoAndExplicitPairSelection() {
        var parser = StreamStatsParser()
        let stats = parser.parse([
            StatsRecord(id: "audio", type: "inbound-rtp", timestampUs: 1, values: ["kind": .string("audio"), "framesPerSecond": .number(999)]),
            StatsRecord(id: "video", type: "inbound-rtp", timestampUs: 1, values: ["mediaType": .string("video"), "framesPerSecond": .number(60), "frameWidth": .string("bad")]),
            StatsRecord(id: "unselected", type: "candidate-pair", timestampUs: 1, values: ["currentRoundTripTime": .number(9)]),
            StatsRecord(id: "selected", type: "candidate-pair", timestampUs: 1, values: ["selected": .bool(true), "currentRoundTripTime": .number(0.01), "localCandidateId": .string("candidate")]),
            StatsRecord(id: "candidate", type: "local-candidate", timestampUs: 1, values: ["candidateType": .string("unknown")]),
        ], firstFrameMs: nil)
        #expect(stats.fps == 60)
        #expect(stats.width == nil)
        #expect(stats.rttMs == 10)
        #expect(stats.localCandidateType == nil)
    }

    @Test @MainActor func samplingPausesIgnoresLateReportsAndResetsOnReconnect() throws {
        let clock = FakeClock()
        let records = try reports()
        var requests: [StreamStatsSampler.Completion] = []
        var samples: [StreamStats?] = []
        let sampler = StreamStatsSampler(scheduler: clock, request: { requests.append($0) }, publish: { samples.append($0) })
        sampler.setActive(true)
        clock.advance(to: 999)
        #expect(requests.isEmpty)
        clock.advance(to: 1000)
        #expect(requests.count == 1)
        clock.advance(to: 5000)
        #expect(requests.count == 1) // No overlapping getStats while its callback is outstanding.
        sampler.setActive(false)
        requests[0](records[0], 240)
        #expect(samples.count == 1)
        #expect(samples[0] == nil)
        #expect(clock.pendingCount == 0)
        sampler.setActive(true)
        clock.advance(to: 6000)
        requests[1](records[0], 500)
        #expect(samples.last??.timeToFirstFrameMs == 500)
        #expect(samples.last??.bitrateKbps == nil)
        clock.advance(to: 7000)
        requests[2](records[1], 500)
        #expect(samples.last??.bitrateKbps == 1000)
        sampler.setActive(false)
        clock.advance(to: 10000)
        #expect(requests.count == 3)
        #expect(clock.pendingCount == 0)
        #expect(samples.last! == nil)
    }
    @Test @MainActor func samplerReleasesItsTimerOnDeallocation() async {
        let clock = FakeClock()
        weak var released: StreamStatsSampler?
        do {
            let sampler = StreamStatsSampler(scheduler: clock, request: { _ in }, publish: { _ in })
            released = sampler
            sampler.setActive(true)
            #expect(clock.pendingCount == 1)
        }
        #expect(released == nil)
        await drain()
        #expect(clock.pendingCount == 0)
    }

}
