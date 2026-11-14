// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Real-time scheduler for a session. Tasks resume on the main actor, including zero-delay work.
@MainActor package final class MainActorScheduler: ReconnectScheduler {
    package init() {}
    package func schedule(delayMs: Int, action: @escaping @MainActor () -> Void) -> any ScheduledTask {
        Handle(delayMs: delayMs, action: action)
    }
    package static func nanoseconds(delayMs: Int) -> UInt64 {
        let milliseconds = min(UInt64(clamping: delayMs), UInt64.max / 1_000_000)
        return milliseconds * 1_000_000
    }
    private final class Handle: ScheduledTask {
        private var task: Task<Void, Never>?
        init(delayMs: Int, action: @escaping @MainActor () -> Void) {
            task = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: MainActorScheduler.nanoseconds(delayMs: delayMs))
                } catch { return }
                guard !Task.isCancelled else { return }
                action()
            }
        }
        func cancel() {
            task?.cancel()
            task = nil
        }
        deinit { task?.cancel() }
    }
}
