// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol
import MobilerunStreamCore
@testable import MobilerunStream
import Testing

struct ApprovalValueTests {
    @Test(arguments: [
        #"{"approvalId":"a","kind":"future","expiresAt":"nope"}"#,
        #"{"approvalId":"a","kind":"future","expiresAt":"nope","details":null}"#,
    ])
    func absentDetailsDecodeAsEmpty(_ json: String) throws {
        let approval = try JSONDecoder().decode(PendingApproval.self, from: Data(json.utf8))
        #expect(approval.approvalId == "a")
        #expect(approval.details == [:])
    }
    @Test func credentialsRedactAllDescriptions() {
        let credentials = StreamCredentials(url: URL(string: "wss://private.example.test/secret?token=url-secret")!, token: "token-secret")
        var reflected = ""
        dump(credentials, to: &reflected)
        #expect(String(describing: credentials) == "StreamCredentials(<redacted>)")
        #expect(String(reflecting: credentials) == "StreamCredentials(<redacted>)")
        #expect(!reflected.contains("private.example.test"))
        #expect(!reflected.contains("url-secret"))
        #expect(!reflected.contains("token-secret"))
    }
    @Test(arguments: [
        (StreamError.notConnected, "Stream is not connected."),
        (.disconnected, "Stream disconnected."),
        (.screenshotFailed, "Screenshot failed."),
        (.screenshotTimeout, "Screenshot timed out."),
    ])
    func neutralErrorMessages(error: StreamError, message: String) {
        #expect(error.localizedDescription == message)
    }
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
        let t = TaskApprovalLabels()
        #expect([t.paymentCardTitle, t.waiting, t.card, t.app, t.domain, t.timeLeft,
                 t.expired, t.approve, t.deny, t.viewSwitch, t.details, t.device] ==
                ["Approve payment", "Waiting for approval", "Card", "App", "Domain", "{time} left",
                 "Approval expired", "Approve", "Deny", "Approval view", "Details", "Device"])
        let stream = StreamLabels()
        #expect([stream.connecting, stream.reconnecting, stream.reconnectingAttempt, stream.unavailable, stream.retry,
                 stream.back, stream.home, stream.recent] ==
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
        #expect(approval.paymentCardDetails() == nil)
        #expect(PendingApproval(approvalId: "a", kind: "payment_card", details: ["label": .string("x"), "targetPackage": .string("a")], expiresAt: "nope").paymentCardDetails()?.card == "x")
        #expect(TaskApprovalLabels().with { $0.waiting = "Loading" }.approve == "Approve")
    }
    @Test func stateMapping() {
        let statuses: [StreamStatus] = [.connecting, .reconnecting(attempt: 2), .connected, .unavailable]
        for status in statuses {
            for control in [false, true] {
                let mapping = StreamPresentation(status: status, hasControl: control)
                #expect(mapping.canControl == (control && status != .unavailable))
                #expect(mapping.showsUnavailable == (status == .unavailable))
                #expect(mapping.showsPlaceholder == (status == .connecting || status == .reconnecting(attempt: 2)))
            }
        }
    }
    @Test func closedPresentationDisablesControls() {
        let mapping = StreamPresentation(status: .connected, hasControl: true, isClosed: true)
        #expect(!mapping.canControl)
    }
    @Test func errorsAndLabels() {
        #expect(TaskApprovalState(error: "failed") == TaskApprovalState(error: "failed"))
        #expect(TaskApprovalState(error: "failed") != TaskApprovalState())
        var announcement = ApprovalErrorAnnouncement()
        let first = announcement.update("failed")
        let repeated = announcement.update("failed")
        let changed = announcement.update("different")
        let cleared = announcement.update(nil)
        let repeatedAfterClear = announcement.update("different")
        #expect(first && !repeated && changed && !cleared && repeatedAfterClear)
        let labels = StreamLabels().with { $0.reconnectingAttempt = "{attempt} of {max}" }
        #expect(labels.statusLabel(.connecting) == "connecting")
        #expect(labels.statusLabel(.reconnecting(attempt: 1)) == "reconnecting")
        #expect(labels.statusLabel(.reconnecting(attempt: 2)) == "2 of 6")
        #expect(labels.statusLabel(.connected) == "connecting")
        #expect(labels.statusLabel(.unavailable) == "connecting")
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
enum ApprovalFailure: Error, Equatable { case http404, http409, timeout }

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
        await settle { decisions == 1 && fetches == 3 && !model.state.isPending }
        #expect(model.state.error == nil)
        #expect(model.state.decision == .approve) // Expired payload still sent to backend.
        model.stop(); clock.advance(to: 9000); await drain(); #expect(fetches == 3)
    }
    @Test func staleFetchAndTaskDisposal() async {
        let clock = FakeClock(), gate = ApprovalGate()
        let model = TaskApprovalModel(taskId: "first", fetchApproval: { _ in try await gate.fetch() }, decide: { _, _, _ in }, scheduler: clock)
        model.start(); await settle { gate.requests.count == 1 }
        model.refetch(); await settle { gate.requests.count == 2 }
        gate.requests[1].resume(returning: PendingApproval(approvalId: "new", kind: "future", expiresAt: "nope"))
        await settle { model.state.approval?.approvalId == "new" }
        gate.requests[0].resume(returning: PendingApproval(approvalId: "old", kind: "future", expiresAt: "nope"))
        await drain(); #expect(model.state.approval?.approvalId == "new")
        model.setTaskId("second"); await settle { gate.requests.count == 3 }
        model.stop(); gate.requests[2].resume(returning: PendingApproval(approvalId: "late", kind: "future", expiresAt: "nope"))
        await drain(); #expect(model.state.approval == nil); #expect(!model.state.isLoading)
    }
    @Test(arguments: [ApprovalFailure.http404, .http409, .timeout])
    func decideFailureAlwaysRefetches(_ failure: ApprovalFailure) async {
        let pending = approval, clock = FakeClock()
        var fetches = 0, reported = 0
        let model = TaskApprovalModel(taskId: "t", fetchApproval: { _ in fetches += 1; return fetches == 1 ? pending : nil }, decide: { _, _, _ in throw failure }, onError: { _ in reported += 1 }, scheduler: clock)
        model.start(); await settle { model.state.approval != nil }
        model.decide(.deny)
        await settle { fetches == 2 && !model.state.isPending && model.state.approval == nil }
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
        #expect(model.error is CancellationError)
        clock.advance(to: 3000); await settle { model.state.approval != nil }
        #expect(model.state.error == nil)
        model.decide(.approve)
        await settle { fetches == 3 && !model.state.isPending }
        #expect(model.error is CancellationError); #expect(reported == 2)
        model.stop()
    }
    @Test func failedSubscriptionFallsBackToPolling() async {
        let clock = FakeClock()
        var fetches = 0
        var reported: [ApprovalFailure] = []
        let model = TaskApprovalModel(taskId: "t", fetchApproval: { _ in fetches += 1; return nil },
            decide: { _, _, _ in }, subscribe: { _, _ in .failure(ApprovalFailure.timeout) },
            onError: { reported.append($0 as! ApprovalFailure) }, scheduler: clock)
        model.start()
        await settle { !model.state.isLoading }
        #expect(reported == [.timeout])
        clock.advance(to: 2999)
        #expect(fetches == 1)
        clock.advance(to: 3000)
        await drain()
        #expect(fetches == 2)
        model.stop()
        clock.advance(to: 6000)
        await drain()
        #expect(fetches == 2)
    }
    @Test func subscriptionFailuresAndCleanupAreSeparate() async {
        let clock = FakeClock()
        var reported = 0
        let model = TaskApprovalModel(taskId: "t", fetchApproval: { _ in throw ApprovalFailure.http404 }, decide: { _, _, _ in },
            subscribe: { _, _ in .failure(ApprovalFailure.timeout) }, onError: { _ in reported += 1 }, scheduler: clock)
        model.start(); await settle { !model.state.isLoading }
        #expect(model.error as? ApprovalFailure == .http404); #expect(reported == 2)
        #expect(clock.pendingCount == 1)
        model.stop()
        let cleanup = TaskApprovalModel(taskId: "t", fetchApproval: { _ in throw ApprovalFailure.http409 }, decide: { _, _, _ in },
            subscribe: { _, _ in .success { .failure(ApprovalFailure.timeout) } }, onError: { _ in reported += 1 }, scheduler: clock)
        cleanup.start(); await settle { !cleanup.state.isLoading }
        let before = cleanup.state.error
        cleanup.stop()
        #expect(cleanup.state.error == before)
        #expect(cleanup.error as? ApprovalFailure == .http409)
        #expect(reported == 4)
    }
    @Test func emptyTaskRetainsRunningIntent() async {
        var tasks: [String] = []
        let model = TaskApprovalModel(taskId: "a", fetchApproval: { tasks.append($0); return nil }, decide: { _, _, _ in }, scheduler: FakeClock())
        model.start(); await settle { tasks == ["a"] }
        model.setTaskId(""); await drain()
        #expect(!model.state.isLoading)
        model.setTaskId("b"); await settle { tasks == ["a", "b"] }
        model.stop(); model.setTaskId("c"); await drain()
        #expect(tasks == ["a", "b"])
        model.start(); await settle { tasks == ["a", "b", "c"] }
        model.stop()
    }
    @Test func subscriptionRefetchDoesNotResubscribe() async {
        var subscriptions = 0, cleanups = 0, fetches = 0
        var changed: (@MainActor () -> Void)?
        let clock = FakeClock()
        let model = TaskApprovalModel(taskId: "t", fetchApproval: { _ in fetches += 1; return nil }, decide: { _, _, _ in }, subscribe: { _, onChange in
            subscriptions += 1; changed = onChange; return .success { cleanups += 1; return .success(()) }
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
        #expect(!model.state.isPending); #expect(model.state.error == nil); #expect(reported == 0)
        model.stop()
    }
}
