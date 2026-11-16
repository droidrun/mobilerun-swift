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
    }

    @Test func missingFieldsAreNil() {
        var parser = StreamStatsParser()
        #expect(parser.parse([], firstFrameMs: nil) == StreamStats(
            fps: nil, width: nil, height: nil, codec: nil, bitrateKbps: nil, rttMs: nil,
            jitterBufferDelayMs: nil, packetsLost: nil, framesDropped: nil, freezeCount: nil,
            decodeTimeMs: nil, localCandidateType: nil, remoteCandidateType: nil, timeToFirstFrameMs: nil))
    }

    @Test(arguments: [
        StatsRecord(id: "video", type: "inbound-rtp", timestampUs: 1_000_000,
                    values: ["kind": .string("video"), "bytesReceived": .number(126000), "framesDecoded": .number(60)]),
        StatsRecord(id: "video", type: "inbound-rtp", timestampUs: 500_000,
                    values: ["kind": .string("video"), "bytesReceived": .number(126000), "framesDecoded": .number(60)]),
        StatsRecord(id: "video", type: "inbound-rtp", timestampUs: 2_000_000,
                    values: ["kind": .string("video"), "bytesReceived": .number(0), "framesDecoded": .number(0),
                             "totalDecodeTime": .number(0), "jitterBufferDelay": .number(0), "jitterBufferEmittedCount": .number(0)]),
        StatsRecord(id: "replacement", type: "inbound-rtp", timestampUs: 2_000_000,
                    values: ["kind": .string("video"), "bytesReceived": .number(126000), "framesDecoded": .number(60)]),
    ])
    func invalidDeltasAreNil(record: StatsRecord) throws {
        var parser = StreamStatsParser()
        _ = parser.parse(try reports()[0], firstFrameMs: 240)
        let stats = parser.parse([record], firstFrameMs: nil)
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

    @Test @MainActor func samplingPublishesCompletionWithoutOverlapOrStaleGenerations() throws {
        let clock = FakeClock()
        let records = try reports()
        var requests: [StreamStatsSampler.Completion] = []
        var samples: [StreamStats?] = []
        let sampler = StreamStatsSampler(scheduler: clock, request: { requests.append($0) }, publish: { samples.append($0) })
        sampler.setActive(true)
        #expect(requests.count == 1)
        #expect(samples.isEmpty)
        clock.advance(to: 900)
        requests[0](records[0], 240)
        #expect(samples.count == 1)
        #expect(samples[0]?.timeToFirstFrameMs == 240)
        clock.advance(to: 1000)
        #expect(requests.count == 2)
        clock.advance(to: 3000)
        #expect(requests.count == 2) // A delayed native report must not overlap another request.
        #expect(samples.count == 1)
        requests[1](records[1], 240)
        #expect(samples.count == 2)
        #expect(samples[1]?.bitrateKbps == 1000)
        clock.advance(to: 4000)
        #expect(requests.count == 3)
        sampler.setActive(false)
        #expect(samples.last! == nil)
        sampler.setActive(true)
        #expect(requests.count == 4)
        requests[2](records[1], 999) // Previous generation cannot publish or clear the new request.
        #expect(samples.count == 3)
        clock.advance(to: 5000)
        #expect(requests.count == 4)
        requests[3](records[1], 500)
        #expect(samples.last??.bitrateKbps == nil)
        #expect(samples.last??.timeToFirstFrameMs == 500)
        sampler.setActive(false)
        clock.advance(to: 10000)
        #expect(requests.count == 4)
        #expect(clock.pendingCount == 0)
    }

    @Test @MainActor func emptyNativeReportsDoNotPublishAnEmptySample() {
        let clock = FakeClock()
        var completion: StreamStatsSampler.Completion?
        var samples: [StreamStats?] = []
        let sampler = StreamStatsSampler(scheduler: clock, request: { completion = $0 }, publish: { samples.append($0) })
        sampler.setActive(true)
        completion?([], nil)
        #expect(samples.isEmpty)
        clock.advance(to: 1000)
        completion?([], 250)
        #expect(samples.isEmpty)
        sampler.setActive(false)
    }

    @Test func firstFrameIsStampedOncePerAttempt() {
        let first = FirstFrameTiming(startedAt: 10)
        #expect(first.value == nil)
        first.stamp(at: 10.25)
        first.stamp(at: 12)
        #expect(first.value == 250)
        let next = FirstFrameTiming(startedAt: 20)
        next.stamp(at: 20.5)
        #expect(next.value == 500)
        #expect(first.value == 250)
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
