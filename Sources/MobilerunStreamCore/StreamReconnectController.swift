// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

/// State of a stream's initial connection or recovery cycle.
package enum StreamReconnectStatus: String, Sendable {
    /// A fresh connection is negotiating.
    case connecting
    /// The connection is established.
    case connected
    /// Waiting for a retry or negotiating a retry.
    case reconnecting
    /// Retry budget exhausted; manual retry or wake can start a fresh cycle.
    case unavailable
}

/// Immutable state emitted by the reconnect controller.
package struct StreamReconnectSnapshot: Sendable, Equatable {
    /// Current connection state.
    package let status: StreamReconnectStatus
    /// Consecutive failures; zero on a fresh connection or after stability refills the budget.
    package let attempt: Int
}

/// Main-actor cancellation handle for one scheduled action, usable by a main-actor host.
@MainActor
package protocol ScheduledTask: Sendable {
    /// Cancels the action; harmless if already fired or cancelled.
    func cancel()
}

/// Main-actor time source supplied by the host. Protocol requirements and actions are isolated
/// to the main actor, allowing Swift 6 hosts to conform without unsafe isolation bridges.
/// The core creates no real timers.
@MainActor
package protocol ReconnectScheduler {
    /// Schedules an action after the given milliseconds. Never invoke it synchronously.
    /// Equal deadlines fire in scheduling order on the main actor.
    func schedule(delayMs: Int, action: @escaping @MainActor () -> Void) -> any ScheduledTask
}

/// Pure reconnect controller for one stream, matching the shared conformance scenarios.
/// Every entry point, scheduled action, and callback runs on the main actor. Call dispose to cancel
/// pending actions before releasing the controller. After disposal, entry points have no effects.
@MainActor
package final class StreamReconnectController {
    private let onRemount: () -> Void
    private let onSnapshot: (StreamReconnectSnapshot) -> Void
    private let onHeal: () -> Void
    private let scheduler: any ReconnectScheduler
    private let random: () -> Double
    private var enabled = false
    private var disposed = false
    private var status: StreamReconnectStatus = .connecting
    private var attempt = 0
    private var everConnectedThisEpoch = false
    private var failureLatched = false
    private var healedThisCycle = false
    private var watchdogTimer: (any ScheduledTask)?
    private var backoffTimer: (any ScheduledTask)?
    private var stabilityTimer: (any ScheduledTask)?

    /// Creates a controller. The host calls attemptMounted after each requested remount.
    /// onHeal refreshes credentials once per recovery cycle; onSnapshot reports state changes.
    /// Callbacks are retained privately. The random source returns a value in [0, 1).
    package init(
        scheduler: any ReconnectScheduler,
        random: @escaping () -> Double = { Double.random(in: 0..<1) },
        onRemount: @escaping () -> Void,
        onSnapshot: @escaping (StreamReconnectSnapshot) -> Void,
        onHeal: @escaping () -> Void
    ) {
        self.scheduler = scheduler
        self.random = random
        self.onRemount = onRemount
        self.onSnapshot = onSnapshot
        self.onHeal = onHeal
    }

    /// Current snapshot, including after disposal.
    package var snapshot: StreamReconnectSnapshot {
        StreamReconnectSnapshot(status: status, attempt: attempt)
    }

    /// Prepares attempt accounting; pass false to defer the watchdog until socket allocation.
    /// Stale mounts during backoff are ignored.
    package func attemptMounted(startWatchdog: Bool = true) {
        guard !disposed else { return }
        enabled = true
        guard !recoveryIsScheduled else { return }
        cancel(&watchdogTimer)
        everConnectedThisEpoch = false
        failureLatched = false
        if status == .connected {
            cancel(&stabilityTimer)
            status = .connecting
            emit()
        }
        guard startWatchdog else { return }
        watchdogTimer = scheduler.schedule(delayMs: ReconnectPolicy.connectTimeoutMs) { [weak self] in
            guard let self, self.enabled else { return }
            self.watchdogTimer = nil
            self.countFailure()
        }
    }

    /// Removes the target, cancels timers, and resets the retry budget.
    package func disable() {
        guard enabled else { return }
        enabled = false
        clearAllTimers()
        everConnectedThisEpoch = false
        failureLatched = false
        healedThisCycle = false
        if status != .connecting || attempt != 0 {
            status = .connecting
            attempt = 0
            emit()
        }
    }

    /// The connection reached connected; cancels a pending remount and starts the stability window.
    package func handleConnected() {
        guard enabled else { return }
        cancel(&watchdogTimer)
        cancel(&backoffTimer)
        everConnectedThisEpoch = true
        failureLatched = false
        if status != .connected {
            status = .connected
            emit()
        }
        cancel(&stabilityTimer)
        stabilityTimer = scheduler.schedule(delayMs: ReconnectPolicy.stabilityMs) { [weak self] in
            guard let self, self.enabled else { return }
            self.stabilityTimer = nil
            self.healedThisCycle = false
            if self.attempt != 0 {
                self.attempt = 0
                self.emit()
            }
        }
    }

    /// Counts a disconnected state only if this mount had connected, once per mount.
    package func handleDisconnected() {
        guard enabled, everConnectedThisEpoch, !failureLatched else { return }
        countFailure()
    }

    /// Counts a terminal negotiation, socket, or peer-connection failure, once per mount.
    package func handleFailure() {
        guard enabled, !failureLatched else { return }
        countFailure()
    }

    /// Defers a target or credential change only during backoff or while unavailable; false after disposal.
    package var shouldDeferTargetChange: Bool { !disposed && recoveryIsScheduled }

    /// Foreground or network recovery: skips backoff, or restarts an exhausted retry cycle.
    package func handleWake() {
        guard enabled else { return }
        if status == .unavailable {
            freshCycle()
        } else if backoffTimer != nil {
            cancel(&backoffTimer)
            onRemount()
        }
    }

    /// Manual retry; only starts a cycle when unavailable.
    package func retry() {
        guard enabled else { return }
        if status == .unavailable { freshCycle() }
    }

    /// Permanently stops timers. Subsequent mutating entry points are no-ops.
    package func dispose() {
        disposed = true
        enabled = false
        clearAllTimers()
    }

    private var recoveryIsScheduled: Bool { backoffTimer != nil || status == .unavailable }
    private func emit() { onSnapshot(snapshot) }

    private func cancel(_ timer: inout (any ScheduledTask)?) {
        timer?.cancel()
        timer = nil
    }

    private func clearAllTimers() {
        cancel(&watchdogTimer)
        cancel(&backoffTimer)
        cancel(&stabilityTimer)
    }

    private func countFailure() {
        guard !recoveryIsScheduled else { return }
        failureLatched = true
        cancel(&watchdogTimer)
        cancel(&stabilityTimer)
        attempt += 1
        if attempt > ReconnectPolicy.maxAttempts {
            status = .unavailable
            emit()
            return
        }
        status = .reconnecting
        emit()
        healOnce()
        let delay = ReconnectPolicy.delayMs(attempt: attempt, random: random())
        backoffTimer = scheduler.schedule(delayMs: delay) { [weak self] in
            guard let self, self.enabled else { return }
            self.backoffTimer = nil
            self.onRemount()
        }
    }

    private func freshCycle() {
        attempt = 0
        failureLatched = false
        everConnectedThisEpoch = false
        healedThisCycle = false
        status = .reconnecting
        emit()
        healOnce()
        onRemount()
    }

    private func healOnce() {
        guard !healedThisCycle else { return }
        healedThisCycle = true
        onHeal()
    }
}
