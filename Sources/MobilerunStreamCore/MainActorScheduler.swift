// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Real-time scheduler for a session. Tasks resume on the main actor, including zero-delay work.
@MainActor public final class MainActorScheduler: ReconnectScheduler {
    public init() {}
    public func schedule(delayMs: Int, action: @escaping @MainActor () -> Void) -> any ScheduledTask {
        Handle(delayMs: delayMs, action: action)
    }
    private final class Handle: ScheduledTask {
        private var task: Task<Void, Never>?
        init(delayMs: Int, action: @escaping @MainActor () -> Void) {
            task = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: UInt64(max(0, delayMs)) * 1_000_000) }
                catch { return }
                guard !Task.isCancelled else { return }
                action()
            }
        }
        func cancel() { task?.cancel(); task = nil }
        deinit { task?.cancel() }
    }
}
