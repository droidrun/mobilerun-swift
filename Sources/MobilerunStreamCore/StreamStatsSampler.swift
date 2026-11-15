// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

/// Fixed one-second publishing ticks; native callbacks only cache reports, never move rate baselines.
@MainActor package final class StreamStatsSampler {
    package typealias Completion = @MainActor @Sendable ([StatsRecord], Double?) -> Void
    private let scheduler: any ReconnectScheduler
    private let request: @MainActor (@escaping Completion) -> Void
    private let publish: @MainActor (StreamStats?) -> Void
    private var timer: (any ScheduledTask)?
    private var parser = StreamStatsParser()
    private var generation = 0
    private var active = false
    private var tickIndex = 0
    private var requesting = false
    private var pending: ([StatsRecord], Double?)?

    package init(scheduler: any ReconnectScheduler,
                 request: @escaping @MainActor (@escaping Completion) -> Void,
                 publish: @escaping @MainActor (StreamStats?) -> Void) {
        self.scheduler = scheduler
        self.request = request
        self.publish = publish
    }

    package func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        generation += 1
        timer?.cancel()
        timer = nil
        parser = StreamStatsParser()
        pending = nil
        requesting = false
        tickIndex = 0
        if active {
            requestReport()
            schedule()
        } else { publish(nil) }
    }

    private func schedule() {
        timer = scheduler.schedule(delayMs: 1000) { [weak self] in self?.tick() }
    }

    private func tick() {
        timer = nil
        tickIndex += 1
        if let pending {
            self.pending = nil
            publish(parser.parse(pending.0, firstFrameMs: pending.1))
        } else {
            // Never reuse stale reports or stretch a rate window over missed publishing ticks.
            parser = StreamStatsParser()
            publish(nil)
        }
        guard active else { return }
        requestReport()
        schedule()
    }

    private func requestReport() {
        guard !requesting else { return }
        requesting = true
        let current = generation
        let requestedAt = tickIndex
        request { [weak self] records, firstFrameMs in
            guard let self, self.active, self.generation == current else { return }
            self.requesting = false
            guard requestedAt == self.tickIndex else { return }
            self.pending = (records, firstFrameMs)
        }
    }

    deinit {
        let timer = timer
        Task { @MainActor in timer?.cancel() }
    }
}
