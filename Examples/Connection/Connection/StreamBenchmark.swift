// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
import Combine
import Foundation
import UIKit
@preconcurrency import LiveKitWebRTC
@testable import MobilerunStream

/// Debug-only measurement alongside the normal native renderer. Never includes credentials.
@MainActor final class StreamBenchmark {
    private var sequence = 0
    private var latest: StreamStats?
    private var subscription: AnyCancellable?
    private let frames = BenchmarkFrames()
    private weak var track: LKRTCVideoTrack?

    struct Result: Codable {
        let firstFrameMs: Double?
        let fps: Double?
        let bitrateKbps: Double?
        let rttMs: Double?
        let localCandidateType: String?
        let remoteCandidateType: String?
        let latencySamplesMs: [Double]
        let appLaunchSamplesMs: [Double]
        let steadySampleCount: Int
    }

    func run(session: DeviceStreamSession, view: DeviceStreamUIView, x: Double, y: Double) async throws -> Result {
        guard (0...1).contains(x), (0...1).contains(y), let track = session.videoTrack else { throw Failure.noVideo }
        self.track = track
        track.add(frames)
        subscription = session.$stats.sink { [weak self] stats in
            self?.latest = stats
            self?.sequence += 1
        }
        defer {
            track.remove(frames)
            self.track = nil
            subscription = nil
        }
        var steady: [StreamStats] = []
        var previous = sequence
        for _ in 0..<10 {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while sequence == previous || latest?.bitrateKbps == nil {
                try await pause(until: deadline)
            }
            previous = sequence
            steady.append(latest!)
        }
        var taps: [Double] = []
        var launches: [Double] = []
        for _ in 0..<10 {
            view.sendSystemKey(.home)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            var baseline = try await nextFrame(after: 0)
            var stable = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while stable < 4 {
                try await Task.sleep(nanoseconds: 100_000_000)
                let next = try await nextFrame(after: baseline.time)
                stable = baseline.difference(next, x: x, y: y) < 1 ? stable + 1 : 0
                baseline = next
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.unstableRegion }
            }
            guard let rect = view.renderedVideoRect else { throw Failure.noVideo }
            let point = CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
            let finger = NSObject()
            let id = ObjectIdentifier(finger)
            let started = ProcessInfo.processInfo.systemUptime
            view.beginPointer(id, at: point)
            view.endPointer(id)
            var tapMs: Double?
            var launchMs: Double?
            var lastTime = baseline.time
            while tapMs == nil || launchMs == nil {
                let next = try await nextFrame(after: lastTime)
                lastTime = next.time
                if next.time >= started {
                    if tapMs == nil, baseline.difference(next, x: x, y: y) >= 4 { tapMs = (next.time - started) * 1000 }
                    if launchMs == nil, baseline.launchDifference(next) >= 4 { launchMs = (next.time - started) * 1000 }
                }
                guard ProcessInfo.processInfo.systemUptime < started + 10 else { throw Failure.noPixelChange }
            }
            taps.append(tapMs!)
            launches.append(launchMs!)
        }
        func mean(_ metric: (StreamStats) -> Double?) -> Double? {
            let values = steady.compactMap(metric)
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return Result(firstFrameMs: latest?.timeToFirstFrameMs, fps: mean(\.fps),
            bitrateKbps: mean(\.bitrateKbps), rttMs: mean(\.rttMs),
            localCandidateType: latest?.localCandidateType, remoteCandidateType: latest?.remoteCandidateType,
            latencySamplesMs: taps, appLaunchSamplesMs: launches, steadySampleCount: steady.count)
    }

    private func pause(until deadline: TimeInterval) async throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.noSample }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    private func nextFrame(after timestamp: TimeInterval) async throws -> BenchmarkFrames.Snapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while true {
            if let value = frames.snapshot(), value.time > timestamp { return value }
            try await pause(until: deadline)
        }
    }
    private enum Failure: Error { case noVideo, noSample, noPixelChange, unstableRegion }
}

/// Samples the luma plane at the video-renderer callback, before compositor/display presentation.
/// The callback timestamp avoids polling quantization; polling only delivers the measured result.
private final class BenchmarkFrames: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Snapshot?
    func snapshot() -> Snapshot? { lock.withLock { latest } }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        let buffer = frame.buffer.toI420()
        let rawWidth = Int(buffer.width)
        let rawHeight = Int(buffer.height)
        let rotation = Int(frame.rotation.rawValue)
        let width = (rotation == 90 || rotation == 270 ? rawHeight : rawWidth) / 4
        let height = (rotation == 90 || rotation == 270 ? rawWidth : rawHeight) / 4
        guard width > 0, height > 0 else { return }
        var luma = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let px = x * 4
                let py = y * 4
                let rx: Int
                let ry: Int
                switch rotation {
                case 90: rx = py; ry = rawHeight - 1 - px
                case 180: rx = rawWidth - 1 - px; ry = rawHeight - 1 - py
                case 270: rx = rawWidth - 1 - py; ry = px
                default: rx = px; ry = py
                }
                luma[y * width + x] = buffer.dataY[ry * Int(buffer.strideY) + rx]
            }
        }
        let next = Snapshot(time: timestamp, width: width, height: height, luma: luma)
        lock.withLock { latest = next }
    }
    struct Snapshot: Sendable {
        let time: TimeInterval
        let width: Int
        let height: Int
        let luma: [UInt8]
        func difference(_ next: Snapshot, x: Double, y: Double) -> Double {
            // 64 × 64 upright video pixels around the actual input position, sampled at quarter scale.
            let cx = Int(x * Double(width))
            let cy = Int(y * Double(height))
            return difference(next, left: max(0, cx - 8), top: max(0, cy - 8),
                              right: min(width, cx + 9), bottom: min(height, cy + 9))
        }
        func launchDifference(_ next: Snapshot) -> Double {
            difference(next, left: width / 5, top: height / 5, right: width * 4 / 5, bottom: height * 3 / 5)
        }
        private func difference(_ next: Snapshot, left: Int, top: Int, right: Int, bottom: Int) -> Double {
            guard next.width == width, next.height == height else { return .infinity }
            var maximum = 0.0
            for y in stride(from: top, to: bottom, by: 4) {
                for x in stride(from: left, to: right, by: 4) {
                    var total = 0.0
                    var count = 0
                    for py in y..<min(y + 4, bottom) {
                        for px in x..<min(x + 4, right) {
                            total += abs(Double(luma[py * width + px]) - Double(next.luma[py * width + px]))
                            count += 1
                        }
                    }
                    maximum = max(maximum, total / Double(count))
                }
            }
            return maximum
        }
    }
}
#endif
