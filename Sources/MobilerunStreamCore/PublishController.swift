// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol

/// One operation at a time. Each operation retains its original peer/socket closures, never a replacement.
@MainActor package final class PublishController {
    package private(set) var state = PublishState() {
        didSet { if state != oldValue { onState?(state) } }
    }
    package var onState: (@MainActor (PublishState) -> Void)?
    package var onError: (@MainActor (PublishFailure, String?) -> Void)?
    private let capabilities: DevicePublishCapabilities?
    private let scheduler: any ReconnectScheduler
    private var operation: Operation?
    private var closed = false
    private var cleanupTask: Task<Void, Never>?

    private final class Operation {
        var token = UUID()
        let options: PublishOptions
        let media: any PublishMediaTransport
        let send: @MainActor ([String: JSONValue]) throws -> Bool
        var continuation: CheckedContinuation<PublishState, Error>?
        var capture: (any PublishCapture)?
        var timer: (any ScheduledTask)?
        var id: String?
        var startSent = false
        var accepted = false
        var active = false
        var attached = false
        init(options: PublishOptions, media: any PublishMediaTransport,
             send: @escaping @MainActor ([String: JSONValue]) throws -> Bool,
             continuation: CheckedContinuation<PublishState, Error>) {
            self.options = options; self.media = media; self.send = send; self.continuation = continuation
        }
    }

    package init(capabilities: DevicePublishCapabilities?, scheduler: any ReconnectScheduler) {
        self.capabilities = capabilities; self.scheduler = scheduler
    }

    package func start(_ options: PublishOptions, media: (any PublishMediaTransport)?, ready: Bool,
                       send: @escaping @MainActor ([String: JSONValue]) throws -> Bool) async throws -> PublishState {
        if let operation {
            let failure = PublishFailure(reason: .publishFailed,
                detail: operation.active && operation.attached ? "already_publishing" : "publish_in_progress")
            onError?(failure, nil)
            throw failure
        }
        do {
            guard !closed else { throw PublishFailure(reason: .disconnected, detail: "session_closed") }
            guard options.audio else { throw PublishFailure(reason: .publishFailed, detail: "invalid_options") }
            guard let capabilities else {
                throw PublishFailure(reason: .publishUnsupported, detail: "capabilities_unavailable")
            }
            guard capabilities.supportsMicrophone, !options.video || capabilities.cameraInjection else {
                throw PublishFailure(reason: .publishUnsupported, detail: "device_capability")
            }
            guard ready else { throw PublishFailure(reason: .disconnected, detail: "not_connected") }
            guard let media, media.supportsPublishReservations, !options.video || media.supportsPublishCamera else {
                throw PublishFailure(reason: .publishUnsupported, detail: "local_media_support")
            }
        } catch let failure as PublishFailure {
            state = PublishState(phase: .error, kinds: options.kinds, reason: failure.reason.rawValue,
                                 message: failure.message, detail: failure.detail, serverReason: failure.serverReason)
            if !closed { onError?(failure, nil) }
            throw failure
        }
        if Task.isCancelled { throw PublishFailure(reason: .publishCancelled) }
        guard let media else { preconditionFailure("validated media") }
        let token = UUID()
        return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let op = Operation(options: options, media: media, send: send, continuation: continuation)
                    op.token = token
                    operation = op
                    op.id = UUID().uuidString
                    snapshot(.starting, op)
                    guard operation === op else { return }
                    op.timer = scheduler.schedule(delayMs: 5_000) { [weak self, weak op] in
                        guard let self, let op, self.operation === op else { return }
                        self.fail(PublishFailure(reason: .publishUnsupported, detail: "response_timeout"), op)
                    }
                    op.startSent = true
                    do {
                        guard try send(["type": .string("publishStart"), "mediaSessionId": .string(op.id!),
                                        "kinds": .array(options.kinds.map { .string($0.rawValue) })]) else {
                            throw PublishFailure(reason: .disconnected)
                        }
                    } catch {
                        op.startSent = false
                        fail(PublishFailure(reason: .disconnected), op)
                    }
                }

            } onCancel: {
                Task { @MainActor [weak self] in
                    guard self?.operation?.token == token else { return }
                    self?.stop()
                }
            }
    }

    /// Called directly by the attempt's socket listener, independently of SDP processing.
    package func receive(_ text: String) {
        guard let op = operation, let id = op.id,
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8)),
              object["type"]?.string == "publishState", object["mediaSessionId"]?.string == id,
              let value = object["state"]?.string,
              ["accepted", "active", "stopped", "rejected", "error"].contains(value) else { return }
        if value == "accepted" || value == "active" {
            if value == "active" { op.active = true }
            if !op.accepted {
                op.accepted = true
                op.timer?.cancel()
                op.timer = scheduler.schedule(delayMs: 30_000) { [weak self, weak op] in
                    guard let self, let op, self.operation === op else { return }
                    self.fail(PublishFailure(reason: .publishTimeout, detail: "active_timeout"), op)
                }
                snapshot(.accepted, op)
                let previousCleanup = cleanupTask
                Task { [weak self, op] in
                    await previousCleanup?.value
                    guard let self, self.operation === op else { return }
                    self.snapshot(.capturing, op)
                    guard self.operation === op else { return }
                    do {
                        let capture = try op.media.makePublishCapture(op.options)
                        op.capture = capture
                        capture.onEnded = { [weak self, weak op] in
                            guard let self, let op, self.operation === op else { return }
                            self.fail(PublishFailure(reason: .publishFailed, detail: "capture_unavailable"), op)
                        }
                        try await capture.start()
                        guard self.operation === op else { capture.stop(); return }
                        for kind in op.options.kinds {
                            guard self.operation === op else { return }
                            do { try capture.attach(kind) }
                            catch { throw error as? PublishFailure ?? PublishFailure(reason: .publishFailed, detail: "attach_failed") }
                        }
                        op.attached = true
                        self.activateIfReady(op)
                    } catch {
                        guard self.operation === op else { return }
                        self.fail(error as? PublishFailure ?? PublishFailure(reason: .publishFailed, detail: "capture_unavailable"), op)
                    }
                }
            }
            activateIfReady(op)
        } else {
            let serverReason = object["reason"]?.string
            let reason: PublishFailureReason
            switch serverReason {
            case "forbidden": reason = .publishNotAllowed
            case "unsupported": reason = .publishUnsupported
            case "busy": reason = .publishBusy
            case "connection_closed": reason = .disconnected
            default: reason = .publishFailed
            }
            fail(PublishFailure(reason: reason, detail: serverReason == "stopped_by_client" ? "remote_stop" : nil,
                                serverReason: serverReason), op)
        }
    }

    private func activateIfReady(_ op: Operation) {
        guard operation === op, op.active, op.attached, state.phase != .active else { return }
        op.timer?.cancel(); op.timer = nil
        snapshot(.active, op)
        let continuation = op.continuation
        op.continuation = nil
        continuation?.resume(returning: state)
    }

    package func stop() {
        guard let op = operation else { return }
        if let failure = cleanup(op) {
            finishFailure(failure, op)
        } else {
            snapshot(.stopped, op, reason: "stopped_by_client")
            op.continuation?.resume(throwing: PublishFailure(reason: .publishCancelled))
            op.continuation = nil
        }
    }
    package func waitForCleanup() async { await cleanupTask?.value }

    /// A native asynchronous write may fail after local stop has already released capture.
    package func sendFailed(mediaSessionId: String) {
        let failure = PublishFailure(reason: .disconnected)
        if let op = operation {
            guard op.id == mediaSessionId else { return }
            fail(failure, op)
        } else if state.mediaSessionId == mediaSessionId, state.phase == .stopped, !closed {
            state = PublishState(phase: .error, mediaSessionId: mediaSessionId, kinds: state.kinds,
                                 reason: failure.reason.rawValue, message: failure.message)
            onError?(failure, mediaSessionId)
        }
    }

    package func disconnect() {
        guard let op = operation else { return }
        fail(PublishFailure(reason: .disconnected), op)
    }
    package func close() { stop(); closed = true; onState = nil; onError = nil }

    private func snapshot(_ phase: PublishPhase, _ op: Operation, reason: String? = nil, failure: PublishFailure? = nil) {
        state = PublishState(phase: phase, mediaSessionId: op.id, kinds: op.options.kinds,
                             reason: reason ?? failure?.reason.rawValue, message: failure?.message,
                             detail: failure?.detail, serverReason: failure?.serverReason)
    }
    private func fail(_ failure: PublishFailure, _ op: Operation) {
        guard operation === op else { return }
        let effectiveFailure = cleanup(op) ?? failure
        finishFailure(effectiveFailure, op)
    }
    private func finishFailure(_ failure: PublishFailure, _ op: Operation) {
        snapshot(.error, op, failure: failure)
        onError?(failure, op.id)
        op.continuation?.resume(throwing: failure)
        op.continuation = nil
    }
    private func cleanup(_ op: Operation) -> PublishFailure? {
        operation = nil // Fence late permission/capture completion before releasing resources.
        op.timer?.cancel(); op.timer = nil
        op.capture?.onEnded = nil
        let capture = op.capture
        capture?.stop(); op.capture = nil
        let previous = cleanupTask
        cleanupTask = Task {
            await previous?.value
            await capture?.waitForStop()
        }
        if op.startSent, let id = op.id {
            do {
                guard try op.send(["type": .string("stopPublish"), "mediaSessionId": .string(id)]) else {
                    return PublishFailure(reason: .disconnected)
                }
            } catch { return PublishFailure(reason: .disconnected) }
        }
        return nil
    }
}
