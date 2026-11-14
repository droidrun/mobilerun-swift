// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

/// State of a stream's initial connection or recovery cycle.
public enum StreamReconnectStatus: String, Sendable {
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
public struct StreamReconnectSnapshot: Sendable, Equatable {
    /// Current connection state.
    public let status: StreamReconnectStatus
    /// Consecutive failures; zero on a fresh connection or after stability refills the budget.
    public let attempt: Int
}

/// Cancellation handle for one scheduled action.
public protocol ScheduledTask {
    /// Cancels the action; harmless if already fired or cancelled.
    func cancel()
}

/// Serial time source supplied by the host. The core creates no real timers.
public protocol ReconnectScheduler {
    /// Schedules an action after the given milliseconds. Never invoke it synchronously.
    /// Equal deadlines fire in scheduling order, on the same serial context as the controller.
    func schedule(delayMs: Int, action: @escaping () -> Void) -> any ScheduledTask
}

/// Pure reconnect controller for one stream, matching the shared conformance scenarios.
/// Call every entry point and scheduled action on one serial context. This mutable controller is
/// deliberately not Sendable. After dispose, entry points have no effects.
public final class StreamReconnectController {
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
    public init(
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

    deinit {
        watchdogTimer?.cancel()
        backoffTimer?.cancel()
        stabilityTimer?.cancel()
    }

    /// Current snapshot, including after disposal.
    public var snapshot: StreamReconnectSnapshot {
        StreamReconnectSnapshot(status: status, attempt: attempt)
    }

    /// A connection started or restarted; arms its watchdog. Stale mounts during backoff are ignored.
    public func attemptMounted() {
        guard !disposed else { return }
        enabled = true
        guard !recoveryIsScheduled else { return }
        watchdogTimer = cancel(watchdogTimer)
        everConnectedThisEpoch = false
        failureLatched = false
        if status == .connected {
            stabilityTimer = cancel(stabilityTimer)
            status = .connecting
            emit()
        }
        watchdogTimer = scheduler.schedule(delayMs: ReconnectPolicy.connectTimeoutMs) { [weak self] in
            guard let self, !self.disposed else { return }
            self.watchdogTimer = nil
            self.countFailure()
        }
    }

    /// Removes the target, cancels timers, and resets the retry budget.
    public func disable() {
        guard !disposed else { return }
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
    public func handleConnected() {
        guard !disposed, enabled else { return }
        watchdogTimer = cancel(watchdogTimer)
        backoffTimer = cancel(backoffTimer)
        everConnectedThisEpoch = true
        failureLatched = false
        if status != .connected {
            status = .connected
            emit()
        }
        stabilityTimer = cancel(stabilityTimer)
        stabilityTimer = scheduler.schedule(delayMs: ReconnectPolicy.stabilityMs) { [weak self] in
            guard let self, !self.disposed else { return }
            self.stabilityTimer = nil
            self.healedThisCycle = false
            if self.attempt != 0 {
                self.attempt = 0
                self.emit()
            }
        }
    }

    /// Counts a disconnected state only if this mount had connected, once per mount.
    public func handleDisconnected() {
        guard !disposed, enabled, everConnectedThisEpoch, !failureLatched else { return }
        countFailure()
    }

    /// Counts a terminal negotiation, socket, or peer-connection failure, once per mount.
    public func handleFailure() {
        guard !disposed, enabled, !failureLatched else { return }
        countFailure()
    }

    /// Defers a target or credential change only during backoff or while unavailable.
    public func shouldDeferTargetChange() -> Bool { recoveryIsScheduled }

    /// Foreground or network recovery: skips backoff, or restarts an exhausted retry cycle.
    public func handleWake() {
        guard !disposed, enabled else { return }
        if status == .unavailable { freshCycle() }
        else if backoffTimer != nil {
            backoffTimer = cancel(backoffTimer)
            onRemount()
        }
    }

    /// Manual retry; only starts a cycle when unavailable.
    public func retry() {
        guard !disposed, enabled else { return }
        if status == .unavailable { freshCycle() }
    }

    /// Permanently stops timers. Subsequent mutating entry points are no-ops.
    public func dispose() {
        disposed = true
        enabled = false
        clearAllTimers()
    }

    private var recoveryIsScheduled: Bool { backoffTimer != nil || status == .unavailable }
    private func emit() { onSnapshot(snapshot) }

    private func cancel(_ timer: (any ScheduledTask)?) -> (any ScheduledTask)? {
        timer?.cancel()
        return nil
    }

    private func clearAllTimers() {
        watchdogTimer = cancel(watchdogTimer)
        backoffTimer = cancel(backoffTimer)
        stabilityTimer = cancel(stabilityTimer)
    }

    private func countFailure() {
        guard !recoveryIsScheduled else { return }
        failureLatched = true
        watchdogTimer = cancel(watchdogTimer)
        stabilityTimer = cancel(stabilityTimer)
        attempt += 1
        if attempt > ReconnectPolicy.maxAttempts {
            status = .unavailable
            emit()
            return
        }
        status = .reconnecting
        emit()
        if !healedThisCycle {
            healedThisCycle = true
            onHeal()
        }
        backoffTimer = scheduler.schedule(delayMs: ReconnectPolicy.delayMs(attempt: attempt, random: random())) { [weak self] in
            guard let self, !self.disposed else { return }
            self.backoffTimer = nil
            self.onRemount()
        }
    }

    private func freshCycle() {
        attempt = 0
        failureLatched = false
        everConnectedThisEpoch = false
        healedThisCycle = true
        status = .reconnecting
        emit()
        onHeal()
        onRemount()
    }
}
