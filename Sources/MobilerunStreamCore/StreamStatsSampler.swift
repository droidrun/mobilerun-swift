// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

/// One-second native requests without overlap; valid completions publish their current report.
@MainActor package final class StreamStatsSampler {
    package typealias Completion = @MainActor @Sendable ([StatsRecord], Double?) -> Void
    private let scheduler: any ReconnectScheduler
    private let request: @MainActor (@escaping Completion) -> Void
    private let publish: @MainActor (StreamStats?) -> Void
    private var timer: (any ScheduledTask)?
    private var parser = StreamStatsParser()
    private var generation = 0
    private var active = false
    private var requesting = false

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
        requesting = false
        if active {
            requestReport()
            schedule()
        } else { publish(nil) }
    }

    private func schedule() {
        guard active else { return }
        timer = scheduler.schedule(delayMs: 1000) { [weak self] in self?.tick() }
    }

    private func tick() {
        timer = nil
        guard active else { return }
        requestReport()
        schedule()
    }

    private func requestReport() {
        guard !requesting else { return }
        requesting = true
        let current = generation
        request { [weak self] records, firstFrameMs in
            guard let self, self.active, self.generation == current else { return }
            self.requesting = false
            guard !records.isEmpty else { return }
            self.publish(self.parser.parse(records, firstFrameMs: firstFrameMs))
        }
    }

    deinit {
        let timer = timer
        Task { @MainActor in timer?.cancel() }
    }
}
