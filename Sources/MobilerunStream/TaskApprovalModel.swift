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
    private enum CodingKeys: String, CodingKey { case approvalId, kind, details, expiresAt, deviceId }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        approvalId = try fields.decode(String.self, forKey: .approvalId)
        kind = try fields.decode(String.self, forKey: .kind)
        details = try fields.decodeIfPresent([String: JSONValue].self, forKey: .details) ?? [:]
        expiresAt = try fields.decode(String.self, forKey: .expiresAt)
        deviceId = try fields.decodeIfPresent(String.self, forKey: .deviceId)
    }
    /// Validated card fields, or nil for another kind or malformed details.
    public func paymentCardDetails() -> PaymentCardDetails? {
        kind == "payment_card" ? parsePaymentCardDetails(.object(details)) : nil
    }
    init(approvalId: String, kind: String, details: [String: JSONValue] = [:],
                expiresAt: String, deviceId: String? = nil) {
        self.approvalId = approvalId; self.kind = kind; self.details = details
        self.expiresAt = expiresAt; self.deviceId = deviceId
    }
}

public enum ApprovalDecision: String, Sendable, Codable { case approve, deny }

public struct PaymentCardDetails: Sendable, Equatable {
    public var card: String
    public var targetPackage: String
    public var targetHost: String?
    init(card: String, targetPackage: String, targetHost: String? = nil) {
        self.card = card; self.targetPackage = targetPackage; self.targetHost = targetHost
    }
}

/// Fetch errors clear on a successful reload; decision errors persist until the next decision/task.
public struct TaskApprovalState: Equatable {
    public var approval: PendingApproval?
    public var isLoading: Bool
    public var isPending: Bool
    public var decision: ApprovalDecision?
    public var error: String?
    init(approval: PendingApproval? = nil, isLoading: Bool = false,
                isPending: Bool = false, decision: ApprovalDecision? = nil, error: String? = nil) {
        self.approval = approval; self.isLoading = isLoading; self.isPending = isPending
        self.decision = decision; self.error = error
    }
}

/// Backend-driven approvals. Start/stop with the host's lifetime; no network API key belongs here.
/// Fetch/decision failures, including cancellation/timeouts, are reported as ordinary errors.
/// Subscription callbacks return Result; error reporting never throws.
@MainActor public final class TaskApprovalModel: ObservableObject {
    public typealias Fetch = @MainActor (String) async throws -> PendingApproval?
    public typealias Decide = @MainActor (String, String, ApprovalDecision) async throws -> Void
    public typealias Unsubscribe = @MainActor @Sendable () -> Result<Void, any Error>
    public typealias Subscribe = @MainActor (String, @escaping @MainActor () -> Void) -> Result<Unsubscribe, any Error>
    @Published public private(set) var state = TaskApprovalState()
    public private(set) var taskId: String
    private let fetch: Fetch
    private let sendDecision: Decide
    private let subscribe: Subscribe?
    private let onError: (@MainActor (any Error) -> Void)?
    private let scheduler: any ReconnectScheduler
    private var poll: (any ScheduledTask)?
    private var unsubscribe: Unsubscribe?
    private var fetches: [Int: Task<Void, Never>] = [:]
    private var deciding: Task<Void, Never>?
    private var generation = 0
    private var latest = 0
    private var wantsRunning = false
    private var active = false
    private static let pollIntervalMs = 3000
    public var error: (any Error)? { decideError ?? fetchError }
    private var fetchError: (any Error)?
    private var decideError: (any Error)?

    public convenience init(taskId: String, fetchApproval: @escaping Fetch, decide: @escaping Decide,
                            subscribe: Subscribe? = nil, onError: (@MainActor (any Error) -> Void)? = nil) {
        self.init(taskId: taskId, fetchApproval: fetchApproval, decide: decide,
                  subscribe: subscribe, onError: onError, scheduler: MainActorScheduler())
    }
    init(taskId: String, fetchApproval: @escaping Fetch, decide: @escaping Decide,
         subscribe: Subscribe? = nil, onError: (@MainActor (any Error) -> Void)? = nil,
         scheduler: any ReconnectScheduler) {
        self.taskId = taskId; self.fetch = fetchApproval; self.sendDecision = decide
        self.subscribe = subscribe; self.onError = onError; self.scheduler = scheduler
    }
    deinit {
        fetches.values.forEach { $0.cancel() }; deciding?.cancel()
        let poll = poll, unsubscribe = unsubscribe, onError = onError
        Task { @MainActor in
            poll?.cancel()
            if case .failure(let error) = unsubscribe?() { onError?(error) }
        }
    }
    /// Idempotent. Empty task identifiers stay disabled.
    public func start() {
        wantsRunning = true
        startIfNeeded()
    }
    private func startIfNeeded() {
        guard !active, !taskId.isEmpty else { return }
        active = true; state.isLoading = true
        refetch()
        let epoch = generation
        if let result = subscribe?(taskId, { [weak self] in
            guard let self, self.active, self.generation == epoch else { return }
            self.refetch()
        }) {
            switch result {
            case .success(let cleanup): unsubscribe = cleanup
            case .failure(let error): fetchError = error; publishError(); report(error)
            }
        }
    }
    /// Cancels only work owned by this controller. Late callback results are discarded.
    public func stop() {
        wantsRunning = false
        stopWork()
    }
    private func stopWork() {
        active = false; generation += 1
        poll?.cancel(); poll = nil
        fetches.values.forEach { $0.cancel() }; fetches.removeAll()
        deciding?.cancel(); deciding = nil
        let cleanup = unsubscribe; unsubscribe = nil
        state.isLoading = false; state.isPending = false
        // Cleanup failures are diagnostic only and cannot overwrite task errors.
        if case .failure(let error) = cleanup?() { report(error) }
    }
    public func setTaskId(_ taskId: String) {
        guard self.taskId != taskId else { return }
        stopWork(); self.taskId = taskId
        fetchError = nil; decideError = nil; state = TaskApprovalState()
        if wantsRunning { startIfNeeded() }
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
            if self.unsubscribe == nil {
                self.poll = self.scheduler.schedule(delayMs: Self.pollIntervalMs) { [weak self] in self?.refetch() }
            }
        }
    }
    /// Expiry never gates this call. Every decision completion, including 404/409, reloads the backend.
    public func decide(_ decision: ApprovalDecision) {
        guard active, !state.isPending, let approval = state.approval else { return }
        state.isPending = true; state.decision = decision; decideError = nil; publishError()
        let epoch = generation, id = taskId
        deciding = Task { [weak self, sendDecision] in
            var failure: (any Error)?
            do { try await sendDecision(id, approval.approvalId, decision) } catch { failure = error }
            guard let self, self.active, self.generation == epoch else { return }
            self.state.isPending = false; self.deciding = nil
            if let failure { self.decideError = failure; self.report(failure) }
            self.publishError(); self.refetch()
        }
    }
    private func publishError() { state.error = error?.localizedDescription }
    private func report(_ error: any Error) { onError?(error) }
}
