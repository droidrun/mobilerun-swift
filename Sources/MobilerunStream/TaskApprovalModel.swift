// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation
import MobilerunProtocol
import MobilerunStreamCore

/// Backend approval payload; unknown kinds and details remain intact.
public struct PendingApproval: Sendable, Equatable, Codable {
    public var approvalId: String
    public var kind: String
    public var details: [String: JSONValue]
    public var expiresAt: String
    public var deviceId: String?
    public init(approvalId: String = "", kind: String = "", details: [String: JSONValue] = [:],
                expiresAt: String = "", deviceId: String? = nil) {
        self.approvalId = approvalId; self.kind = kind; self.details = details
        self.expiresAt = expiresAt; self.deviceId = deviceId
    }
    public func with(_ update: (inout Self) -> Void) -> Self { var copy = self; update(&copy); return copy }
}

public enum ApprovalDecision: String, Sendable, Codable { case approve, deny }

public struct PaymentCardDetails: Sendable, Equatable {
    public var card: String
    public var targetPackage: String
    public var targetHost: String?
    public init(card: String = "", targetPackage: String = "", targetHost: String? = nil) {
        self.card = card; self.targetPackage = targetPackage; self.targetHost = targetHost
    }
    public func with(_ update: (inout Self) -> Void) -> Self { var copy = self; update(&copy); return copy }
}

public func parsePaymentCardDetails(_ details: JSONValue) -> PaymentCardDetails? {
    paymentCardFields(details).map { PaymentCardDetails(card: $0.card, targetPackage: $0.package, targetHost: $0.host) }
}
public func remainingMs(expiresAt: String, nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Double {
    approvalRemainingMs(expiresAt, nowMs: nowMs)
}
public func formatRemaining(_ ms: Double) -> String { approvalFormattedRemaining(ms) }

/// Fetch errors clear on a successful reload; decision errors persist until the next decision/task.
public struct TaskApprovalState {
    public var approval: PendingApproval?
    public var isLoading: Bool
    public var isDeciding: Bool
    public var decision: ApprovalDecision?
    public var error: (any Error)?
    public init(approval: PendingApproval? = nil, isLoading: Bool = false,
                isDeciding: Bool = false, decision: ApprovalDecision? = nil, error: (any Error)? = nil) {
        self.approval = approval; self.isLoading = isLoading; self.isDeciding = isDeciding
        self.decision = decision; self.error = error
    }
    public func with(_ update: (inout Self) -> Void) -> Self { var copy = self; update(&copy); return copy }
}

/// Backend-driven approvals. Start/stop with the host's lifetime; no network API key belongs here.
/// Throwing integrator callbacks, including cancellation/timeouts, are reported as ordinary errors.
@MainActor public final class TaskApprovalModel: ObservableObject {
    public typealias Fetch = @MainActor (String) async throws -> PendingApproval?
    public typealias Decide = @MainActor (String, String, ApprovalDecision) async throws -> Void
    public typealias Unsubscribe = @MainActor @Sendable () throws -> Void
    public typealias Subscribe = @MainActor (String, @escaping @MainActor () -> Void) throws -> Unsubscribe
    @Published public private(set) var state = TaskApprovalState()
    public private(set) var taskId: String
    private let fetch: Fetch
    private let sendDecision: Decide
    private let subscribe: Subscribe?
    private let onError: (@MainActor (any Error) throws -> Void)?
    private let scheduler: any ReconnectScheduler
    private var poll: (any ScheduledTask)?
    private var unsubscribe: Unsubscribe?
    private var fetches: [Int: Task<Void, Never>] = [:]
    private var deciding: Task<Void, Never>?
    private var generation = 0
    private var latest = 0
    private var active = false
    private var fetchError: (any Error)?
    private var decideError: (any Error)?

    public convenience init(taskId: String, fetchApproval: @escaping Fetch, decide: @escaping Decide,
                            subscribe: Subscribe? = nil, onError: (@MainActor (any Error) throws -> Void)? = nil) {
        self.init(taskId: taskId, fetchApproval: fetchApproval, decide: decide,
                  subscribe: subscribe, onError: onError, scheduler: MainActorScheduler())
    }
    init(taskId: String, fetchApproval: @escaping Fetch, decide: @escaping Decide,
         subscribe: Subscribe? = nil, onError: (@MainActor (any Error) throws -> Void)? = nil,
         scheduler: any ReconnectScheduler) {
        self.taskId = taskId; self.fetch = fetchApproval; self.sendDecision = decide
        self.subscribe = subscribe; self.onError = onError; self.scheduler = scheduler
    }
    deinit {
        fetches.values.forEach { $0.cancel() }; deciding?.cancel()
        let poll = poll, unsubscribe = unsubscribe
        Task { @MainActor in poll?.cancel(); try? unsubscribe?() }
    }
    /// Idempotent. Empty task identifiers stay disabled.
    public func start() {
        guard !active, !taskId.isEmpty else { return }
        active = true; state.isLoading = true
        refetch()
        let epoch = generation
        do {
            unsubscribe = try subscribe?(taskId, { [weak self] in
                guard let self, self.active, self.generation == epoch else { return }
                self.refetch()
            })
        } catch { report(error); fetchError = error; publishError() }
    }
    /// Cancels only work owned by this controller. Late callback results are discarded.
    public func stop() {
        active = false; generation += 1
        poll?.cancel(); poll = nil
        fetches.values.forEach { $0.cancel() }; fetches.removeAll()
        deciding?.cancel(); deciding = nil
        let cleanup = unsubscribe; unsubscribe = nil
        state.isLoading = false; state.isDeciding = false
        do { try cleanup?() } catch { fetchError = error; publishError(); report(error) }
    }
    public func setTaskId(_ taskId: String) {
        guard self.taskId != taskId else { return }
        let restart = active
        stop(); self.taskId = taskId
        fetchError = nil; decideError = nil; state = TaskApprovalState()
        if restart { start() }
    }
    public func refetch() {
        guard active else { return }
        poll?.cancel(); poll = nil
        latest += 1
        let seq = latest, epoch = generation, id = taskId
        fetches[seq] = Task { [weak self, fetch] in
            let result: Result<PendingApproval?, any Error>
            do { result = .success(try await fetch(id)) } catch { result = .failure(error) }
            guard let self else { return }
            self.fetches[seq] = nil
            guard self.active, self.generation == epoch, self.latest == seq else { return }
            switch result {
            case .success(let approval): self.state.approval = approval; self.fetchError = nil
            case .failure(let error): self.fetchError = error; self.report(error)
            }
            self.state.isLoading = false; self.publishError()
            if self.subscribe == nil {
                self.poll = self.scheduler.schedule(delayMs: 3000) { [weak self] in self?.refetch() }
            }
        }
    }
    /// Expiry never gates this call. Every decision completion, including 404/409, reloads the backend.
    public func decide(_ decision: ApprovalDecision) {
        guard active, !state.isDeciding, let approval = state.approval else { return }
        state.isDeciding = true; state.decision = decision; decideError = nil; publishError()
        let epoch = generation, id = taskId
        deciding = Task { [weak self, sendDecision] in
            var failure: (any Error)?
            do { try await sendDecision(id, approval.approvalId, decision) } catch { failure = error }
            guard let self, self.active, self.generation == epoch else { return }
            self.state.isDeciding = false; self.deciding = nil
            if let failure { self.decideError = failure; self.report(failure) }
            self.publishError(); self.refetch()
        }
    }
    private func publishError() { state.error = decideError ?? fetchError }
    private func report(_ error: any Error) { try? onError?(error) }
}
