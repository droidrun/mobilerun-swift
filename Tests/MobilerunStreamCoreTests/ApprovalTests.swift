// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol
import MobilerunStreamCore
@testable import MobilerunStream
import Testing

struct ApprovalValueTests {
    @Test func paymentCardVectors() {
        #expect(parsePaymentCardDetails(.object(["label": .string("Visa 4242"), "targetPackage": .string("com.shop"), "targetHost": .string("shop.com")])) == PaymentCardDetails(card: "Visa 4242", targetPackage: "com.shop", targetHost: "shop.com"))
        #expect(parsePaymentCardDetails(.object(["credentialName": .string("corp"), "targetPackage": .string("com.shop")])) == PaymentCardDetails(card: "corp", targetPackage: "com.shop"))
        for value: JSONValue in [.null, .string("card"), .object(["label": .string("x")]), .object(["targetPackage": .string("com.shop")]), .object(["label": .number(1), "targetPackage": .string("a")]), .object(["label": .string(""), "targetPackage": .string("a")]), .object(["label": .string("x"), "targetPackage": .string("")])] {
            #expect(parsePaymentCardDetails(value) == nil)
        }
        #expect(parsePaymentCardDetails(.object(["label": .string("x"), "targetPackage": .string("a"), "targetHost": .number(3)])) == PaymentCardDetails(card: "x", targetPackage: "a"))
        #expect(parsePaymentCardDetails(.object(["label": .string(""), "credentialName": .string("corp"), "targetPackage": .string("a")]))?.card == "corp")
    }
    @Test func labelDefaults() {
        let t = StreamLabels()
        #expect([t.paymentCardTitle, t.waiting, t.card, t.app, t.domain, t.timeLeft,
                 t.expired, t.approve, t.deny, t.viewSwitch, t.details, t.device] ==
                ["Approve payment", "Waiting for approval", "Card", "App", "Domain", "{time} left",
                 "Approval expired", "Approve", "Deny", "Approval view", "Details", "Device"])
        #expect([t.connecting, t.reconnecting, t.reconnectingAttempt, t.unavailable, t.retry,
                 t.back, t.home, t.recent] ==
                ["connecting", "reconnecting", "reconnecting ({attempt}/{max})", "device stream unavailable",
                 "Retry", "Back", "Home", "Recent"])
    }
    @Test func remainingVectors() {
        let at = "2026-01-01T00:10:00.000Z"
        let base = ISO8601DateFormatter().date(from: "2026-01-01T00:10:00Z")!.timeIntervalSince1970 * 1000
        #expect(remainingMs(expiresAt: at, nowMs: base - 5000) == 5000)
        #expect(remainingMs(expiresAt: at, nowMs: base + 1) == -1)
        #expect(remainingMs(expiresAt: "nope", nowMs: base) == 0)
        for (ms, expected) in [(0.0, "0s"), (59001, "1m 0s"), (3725000, "1h 2m 5s"), (298000, "4m 58s"), (45000, "45s"), (3600000, "1h 0m 0s"), (-5, "0s")] {
            #expect(formatRemaining(ms) == expected)
        }
    }
    @Test func extensiblePayload() throws {
        let approval = PendingApproval(approvalId: "a", kind: "future", details: ["nested": .object(["x": .bool(true)])], expiresAt: "nope")
        #expect(try JSONDecoder().decode(PendingApproval.self, from: JSONEncoder().encode(approval)) == approval)
        #expect(approval.with { $0.deviceId = "device" }.kind == "future")
        #expect(StreamLabels().with { $0.connecting = "Loading" }.approve == "Approve")
    }
    @Test func stateMapping() {
        let statuses: [StreamStatus] = [.connecting, .reconnecting(attempt: 2), .connected, .unavailable, .closed]
        for status in statuses {
            for control in [false, true] {
                let mapping = StreamPresentation(status: status, hasControl: control)
                #expect(mapping.canControl == (control && status != .unavailable))
                #expect(mapping.showsUnavailable == (status == .unavailable))
                #expect(mapping.showsPlaceholder == (status == .connecting || status == .reconnecting(attempt: 2)))
            }
        }
    }
    @Test func wakeTransitions() {
        var transitions = StreamWakeTransitions(foreground: true)
        let wake0 = transitions.setForeground(true)
        #expect(!wake0)
        let wake1 = transitions.setOnline(true)
        #expect(!wake1)
        let wake2 = transitions.setOnline(true)
        #expect(!wake2)
        let wake3 = transitions.setForeground(false)
        #expect(!wake3)
        let wake4 = transitions.setForeground(true)
        #expect(wake4)
        let wake5 = transitions.setForeground(true)
        #expect(!wake5)
        let wake6 = transitions.setOnline(false)
        #expect(!wake6)
        let wake7 = transitions.setOnline(true)
        #expect(wake7)
        let wake8 = transitions.setOnline(true)
        #expect(!wake8)
    }
}

@MainActor private final class ApprovalGate {
    var requests: [CheckedContinuation<PendingApproval?, any Error>] = []
    func fetch() async throws -> PendingApproval? {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
}
enum ApprovalFailure: Error { case http404, http409, timeout }

@Suite @MainActor struct ApprovalControllerTests {
    private var approval: PendingApproval { PendingApproval(approvalId: "a", kind: "payment_card", expiresAt: "2000-01-01T00:00:00Z") }
    @Test func pollingAndDecisionRefetch() async {
        let clock = FakeClock()
        var fetches = 0, decisions = 0
        let pending = approval
        let model = TaskApprovalModel(taskId: "t", fetchApproval: { _ in fetches += 1; return pending }, decide: { task, id, decision in
            #expect(task == "t" && id == "a" && decision == .approve); decisions += 1
        }, scheduler: clock)
        model.start(); model.start()
        await settle { !model.state.isLoading }
        #expect(fetches == 1)
        clock.advance(to: 2999); #expect(fetches == 1)
        clock.advance(to: 3000); await settle { fetches == 2 }
        await drain()
        model.decide(.approve); model.decide(.deny)
        await settle { decisions == 1 && fetches == 3 && !model.state.isDeciding }
        #expect(model.state.error == nil)
        #expect(model.state.decision == .approve) // Expired payload still sent to backend.
        model.stop(); clock.advance(to: 9000); await drain(); #expect(fetches == 3)
    }
    @Test func staleFetchAndTaskDisposal() async {
        let clock = FakeClock(), gate = ApprovalGate()
        let model = TaskApprovalModel(taskId: "first", fetchApproval: { _ in try await gate.fetch() }, decide: { _, _, _ in }, scheduler: clock)
        model.start(); await settle { gate.requests.count == 1 }
        model.refetch(); await settle { gate.requests.count == 2 }
        gate.requests[1].resume(returning: PendingApproval(approvalId: "new"))
        await settle { model.state.approval?.approvalId == "new" }
        gate.requests[0].resume(returning: PendingApproval(approvalId: "old"))
        await drain(); #expect(model.state.approval?.approvalId == "new")
        model.setTaskId("second"); await settle { gate.requests.count == 3 }
        model.stop(); gate.requests[2].resume(returning: PendingApproval(approvalId: "late"))
        await drain(); #expect(model.state.approval == nil); #expect(!model.state.isLoading)
    }
    @Test(arguments: [ApprovalFailure.http404, .http409, .timeout])
    func decideFailureAlwaysRefetches(_ failure: ApprovalFailure) async {
        let pending = approval, clock = FakeClock()
        var fetches = 0, reported = 0
        let model = TaskApprovalModel(taskId: "t", fetchApproval: { _ in fetches += 1; return fetches == 1 ? pending : nil }, decide: { _, _, _ in throw failure }, onError: { _ in reported += 1; throw ApprovalFailure.timeout }, scheduler: clock)
        model.start(); await settle { model.state.approval != nil }
        model.decide(.deny)
        await settle { fetches == 2 && !model.state.isDeciding && model.state.approval == nil }
        #expect(model.state.error != nil); #expect(reported == 1)
        model.stop()
    }
    @Test func integratorCancellationIsFailure() async {
        let pending = approval, clock = FakeClock()
        var fetches = 0, reported = 0
        let model = TaskApprovalModel(taskId: "t", fetchApproval: { _ in
            fetches += 1
            if fetches == 1 { throw CancellationError() }
            return pending
        }, decide: { _, _, _ in throw CancellationError() }, onError: { _ in reported += 1 }, scheduler: clock)
        model.start(); await settle { !model.state.isLoading }
        #expect(model.state.error is CancellationError)
        clock.advance(to: 3000); await settle { model.state.approval != nil }
        #expect(model.state.error == nil)
        model.decide(.approve)
        await settle { fetches == 3 && !model.state.isDeciding }
        #expect(model.state.error is CancellationError); #expect(reported == 2)
        model.stop()
    }
    @Test func allCallbacksGuardTimeouts() async {
        let clock = FakeClock()
        var reported = 0
        let model = TaskApprovalModel(taskId: "t", fetchApproval: { _ in throw ApprovalFailure.timeout }, decide: { _, _, _ in }, subscribe: { _, _ in throw ApprovalFailure.timeout }, onError: { _ in reported += 1; throw ApprovalFailure.timeout }, scheduler: clock)
        model.start(); await settle { !model.state.isLoading }
        #expect(model.state.error != nil); #expect(reported == 2)
        #expect(clock.pendingCount == 0) // A supplied push source suppresses polling.
        model.stop()
        let cleanup = TaskApprovalModel(taskId: "t", fetchApproval: { _ in nil }, decide: { _, _, _ in }, subscribe: { _, _ in { throw ApprovalFailure.timeout } }, onError: { _ in reported += 1; throw ApprovalFailure.timeout }, scheduler: clock)
        cleanup.start(); await settle { !cleanup.state.isLoading }; cleanup.stop()
        #expect(reported == 3)
    }
    @Test func subscriptionRefetchDoesNotResubscribe() async {
        var subscriptions = 0, cleanups = 0, fetches = 0
        var changed: (@MainActor () -> Void)?
        let clock = FakeClock()
        let model = TaskApprovalModel(taskId: "t", fetchApproval: { _ in fetches += 1; return nil }, decide: { _, _, _ in }, subscribe: { _, onChange in
            subscriptions += 1; changed = onChange; return { cleanups += 1 }
        }, scheduler: clock)
        model.start(); await settle { fetches == 1 }
        changed?(); await settle { fetches == 2 }
        #expect(subscriptions == 1); #expect(clock.pendingCount == 0)
        model.stop(); changed?(); await drain()
        #expect(cleanups == 1 && fetches == 2)
    }
    @Test func disposalSilentlyCancelsDecisionAndOldTask() async {
        let pending = approval
        var reported = 0
        let gate = OfferGate()
        let model = TaskApprovalModel(taskId: "t", fetchApproval: { _ in pending }, decide: { _, _, _ in try await gate.wait() }, onError: { _ in reported += 1 }, scheduler: FakeClock())
        model.start(); await settle { model.state.approval != nil }
        model.decide(.approve); await settle { gate.continuation != nil }
        model.setTaskId("next")
        gate.cancel(); await drain()
        #expect(!model.state.isDeciding); #expect(model.state.error == nil); #expect(reported == 0)
        model.stop()
    }
}

@Test("Credentials poll at 3000ms without consuming recovery budget") @MainActor
func sessionCredentialsPoll() async throws {
    let h = try SessionHarness(); h.returnNil = true
    h.engine.start(); await settle { h.credentialCalls == 1 }; await drain()
    #expect(h.engine.status == .connecting)
    for n in 1...12 {
        h.clock.advance(to: n * 3000 - 1); #expect(h.credentialCalls == n)
        h.clock.advance(to: n * 3000); await settle { h.credentialCalls == n + 1 }; await drain()
        #expect(h.engine.status == .connecting)
    }
    h.returnNil = false; h.engine.handleWake()
    await settle { h.sockets.count == 1 }
    h.engine.close(); h.clock.advance(to: 100000); await drain()
    #expect(h.credentialCalls == 14)
}

@Test("Background stops keepalive; foreground resumes and wake skips backoff") @MainActor
func sessionLifecycle() async throws {
    let h = try SessionHarness(); defer { h.engine.close() }
    try await h.connected(); let ws = h.sockets[0]
    h.engine.setHidden(true); h.clock.advance(to: 30000)
    #expect(ws.frames("keepAlive").isEmpty)
    h.engine.setHidden(false); h.clock.advance(to: 40000)
    #expect(ws.frames("keepAlive").count == 1)
    ws.onEvent?(.closed); #expect(h.engine.status == .reconnecting(attempt: 1))
    h.engine.handleWake(); await settle { h.sockets.count == 2 }
}
