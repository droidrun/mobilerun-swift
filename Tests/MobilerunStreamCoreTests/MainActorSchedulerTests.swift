// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import MobilerunStreamCore
import Testing

// This host implementation compiles in Swift 6 without nonisolated or unchecked bridges.
@MainActor
private final class TaskMainScheduler: ReconnectScheduler {
    @MainActor
    private final class Handle: ScheduledTask {
        let task: Task<Void, Never>

        init(_ task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
    }

    private(set) var delays: [Int] = []

    func schedule(delayMs: Int, action: @escaping @MainActor () -> Void) -> any ScheduledTask {
        delays.append(delayMs)
        return Handle(Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, delayMs)) * 1_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            action()
        })
    }
}

@Test("Main-actor host can use Task timers with the reconnect controller")
@MainActor
func taskMainScheduler() async {
    let scheduler = TaskMainScheduler()
    let controller = StreamReconnectController(
        scheduler: scheduler, onRemount: {}, onSnapshot: { _ in }, onHeal: {})
    await withCheckedContinuation { continuation in
        _ = scheduler.schedule(delayMs: 0) {
            controller.attemptMounted()
            continuation.resume()
        }
    }
    #expect(scheduler.delays == [0, ReconnectPolicy.connectTimeoutMs])
    #expect(controller.snapshot.status == .connecting)
    controller.dispose()
}

@Test("Disposal clears target deferral even after exhausting the retry budget")
@MainActor
func disposedTargetDeferral() {
    let clock = FakeClock()
    let controller = StreamReconnectController(
        scheduler: clock, random: { 0.5 }, onRemount: {}, onSnapshot: { _ in }, onHeal: {})
    controller.attemptMounted()
    for attempt in 1...7 {
        controller.handleFailure()
        guard attempt <= ReconnectPolicy.maxAttempts else { break }
        clock.advance(to: clock.now + ReconnectPolicy.delayMs(attempt: attempt, random: 0.5))
        controller.attemptMounted()
    }
    #expect(controller.snapshot.status == .unavailable)
    #expect(controller.shouldDeferTargetChange)
    controller.dispose()
    #expect(!controller.shouldDeferTargetChange)
}
