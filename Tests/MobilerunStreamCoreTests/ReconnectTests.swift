// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import MobilerunProtocol
import MobilerunStreamCore
import Testing

@Test("Reconnect scenario replay", arguments: try fixture("reconnect/scenarios.json", as: ScenarioFile.self).scenarios)
func replay(_ scenario: Scenario) {
    let clock = FakeClock()
    var healCalls = 0
    var remountCalls = 0
    let controller = StreamReconnectController(scheduler: clock, random: { scenario.random },
                                               onRemount: { remountCalls += 1 }, onSnapshot: { _ in },
                                               onHeal: { healCalls += 1 })
    defer { controller.dispose() }
    var evaluated = 0
    for i in 0...scenario.steps.count {
        // Expectations occur before the next event, even when their timestamps are equal.
        for expected in scenario.expect.filter({ $0.afterSteps == i }).sorted(by: { $0.atMs < $1.atMs }) {
            clock.advance(to: expected.atMs)
            #expect(controller.snapshot.status.rawValue == expected.status)
            #expect(controller.snapshot.attempt == expected.attempt)
            #expect(healCalls == expected.healCalls)
            #expect(remountCalls == expected.remountCalls)
            if let deferred = expected.deferTargetChange {
                #expect(controller.shouldDeferTargetChange() == deferred)
            }
            if let pending = expected.pendingTimers { #expect(clock.pendingCount == pending) }
            evaluated += 1
        }
        guard i < scenario.steps.count else { break }
        let step = scenario.steps[i]
        clock.advance(to: step.atMs)
        switch step.event {
        case "attempt_mounted": controller.attemptMounted()
        case "connected": controller.handleConnected()
        case "disconnected": controller.handleDisconnected()
        case "failure": controller.handleFailure()
        case "wake": controller.handleWake()
        case "retry": controller.retry()
        case "disable": controller.disable()
        case "dispose": controller.dispose()
        default: Issue.record("Unhandled event \(step.event)")
        }
    }
    #expect(evaluated == scenario.expect.count)
}

@Test("Reconnect delay table", arguments: try fixture("reconnect/policy.json", as: Policy.self).delayCases)
func delays(_ item: Policy.Delay) {
    #expect(ReconnectPolicy.delayMs(attempt: item.attempt, random: item.random) == item.delayMs)
}

@Test("Reconnect policy constants and watchdog budget")
func policy() throws {
    let policy = try fixture("reconnect/policy.json", as: Policy.self)
    #expect(ReconnectPolicy.maxAttempts == policy.maxAttempts)
    #expect(ReconnectPolicy.connectTimeoutMs == policy.connectTimeoutMs)
    #expect(ReconnectPolicy.stabilityMs == policy.stabilityMs)
    #expect(ReconnectPolicy.baseDelayMs == policy.backoff.baseDelayMs)
    #expect(ReconnectPolicy.maxDelayMs == policy.backoff.maxDelayMs)
    #expect(SignallingTiming.wsOpenTimeoutMs == policy.wsOpenTimeoutMs)
    #expect(SignallingTiming.rtcConfigTimeoutMs == policy.rtcConfigTimeoutMs)
    #expect(ReconnectPolicy.connectTimeoutMs > SignallingTiming.wsOpenTimeoutMs + SignallingTiming.rtcConfigTimeoutMs)
    #expect(ReconnectPolicy.delayMs(attempt: Int.min, random: 0.5) == 1000)
    #expect(ReconnectPolicy.delayMs(attempt: Int.max, random: 0.5) == 30000)
}

@Test("Dispose permanently ignores every mutating entry point")
func disposedEntryPoints() {
    let clock = FakeClock()
    var callbackCount = 0
    let controller = StreamReconnectController(scheduler: clock, random: { 0.5 },
                                               onRemount: { callbackCount += 1 },
                                               onSnapshot: { _ in callbackCount += 1 },
                                               onHeal: { callbackCount += 1 })
    controller.attemptMounted()
    controller.handleFailure()
    controller.dispose()
    let before = controller.snapshot
    let callbacksBefore = callbackCount
    controller.attemptMounted()
    controller.handleConnected()
    controller.handleDisconnected()
    controller.handleFailure()
    controller.handleWake()
    controller.retry()
    controller.disable()
    controller.dispose()
    clock.advance(to: 1_000_000)
    #expect(controller.snapshot == before)
    #expect(callbackCount == callbacksBefore)
    #expect(clock.pendingCount == 0)
}

@Test("Snapshot callback follows state changes and stability reset")
func snapshotCallback() {
    let clock = FakeClock()
    var snapshots: [StreamReconnectSnapshot] = []
    let controller = StreamReconnectController(scheduler: clock, random: { 0.5 },
                                               onRemount: {}, onSnapshot: { snapshots.append($0) }, onHeal: {})
    controller.attemptMounted()
    controller.handleFailure()
    controller.handleFailure()
    clock.advance(to: 1000)
    controller.attemptMounted()
    controller.handleConnected()
    clock.advance(to: 31_000)
    #expect(snapshots.map(\.status) == [.reconnecting, .connected, .connected])
    #expect(snapshots.map(\.attempt) == [1, 1, 0])
    controller.dispose()
}

@Test("Fake clock fires equal deadlines in scheduling order, including newly scheduled actions")
func clockOrdering() {
    let clock = FakeClock()
    var order: [Int] = []
    _ = clock.schedule(delayMs: 1) {
        order.append(1)
        _ = clock.schedule(delayMs: 0) { order.append(3) }
    }
    _ = clock.schedule(delayMs: 1) { order.append(2) }
    let cancelled = clock.schedule(delayMs: 1) { order.append(99) }
    cancelled.cancel()
    clock.advance(to: 1)
    #expect(order == [1, 2, 3])
    #expect(clock.pendingCount == 0)
}
