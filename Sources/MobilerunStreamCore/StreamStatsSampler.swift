// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

/// Serial, non-overlapping sampling with generation checks for late native callbacks.
@MainActor package final class StreamStatsSampler {
    package typealias Completion = @MainActor @Sendable ([StatsRecord], Double?) -> Void
    private let scheduler: any ReconnectScheduler
    private let request: @MainActor (@escaping Completion) -> Void
    private let publish: @MainActor (StreamStats?) -> Void
    private var timer: (any ScheduledTask)?
    private var parser = StreamStatsParser()
    private var generation = 0
    private var active = false

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
        if active { schedule() } else { publish(nil) }
    }

    private func schedule() {
        timer = scheduler.schedule(delayMs: 1000) { [weak self] in self?.sample() }
    }

    private func sample() {
        timer = nil
        let current = generation
        request { [weak self] records, firstFrameMs in
            guard let self, self.active, self.generation == current else { return }
            self.publish(self.parser.parse(records, firstFrameMs: firstFrameMs))
            self.schedule()
        }
    }

    deinit {
        let timer = timer
        Task { @MainActor in timer?.cancel() }
    }
}
