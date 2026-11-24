// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import MobilerunProtocol
@testable import MobilerunStreamCore
@testable import MobilerunStream

@MainActor final class FakePublishCapture: PublishCapture {
    var onEnded: (@MainActor () -> Void)?
    var attachments: [PublishKind] = []
    var stopped = false
    var failure: PublishFailure?
    var failVideoAttach = false
    var gate: CheckedContinuation<Void, Never>?
    var holdStart = false
    var starting = false
    func start() async throws {
        starting = true
        if holdStart { await withCheckedContinuation { gate = $0 } }
        if let failure { throw failure }
    }
    func attach(_ kind: PublishKind) throws {
        if kind == .video && failVideoAttach { throw FakeFailure.negotiation }
        attachments.append(kind)
    }
    func stop() { stopped = true; onEnded = nil }
    func finishStart() { gate?.resume(); gate = nil }
}
@MainActor final class FakePublishMedia: PublishMediaTransport {
    var supportsPublishCamera = true
    var supportsPublishReservations = true
    var captures: [FakePublishCapture] = []
    var next = FakePublishCapture()
    func makePublishCapture(_ options: PublishOptions) throws -> any PublishCapture {
        captures.append(next)
        return next
    }
}
@MainActor private final class PublishHarness {
    let clock = FakeClock()
    let media = FakePublishMedia()
    let controller: PublishController
    var frames: [[String: JSONValue]] = []
    var failures: [PublishFailure] = []
    var snapshots: [PublishState] = []
    var throwFrameType: String?
    var id: String { controller.state.mediaSessionId! }
    init(capabilities: DevicePublishCapabilities? = DevicePublishCapabilities(
        microphoneInjection: true, cameraInjection: true, mediaInjectionTransport: "direct")) {
        controller = PublishController(capabilities: capabilities, scheduler: clock)
        controller.onState = { [weak self] in self?.snapshots.append($0) }
        controller.onError = { [weak self] error, _ in self?.failures.append(error) }
    }
    func start(_ options: PublishOptions = PublishOptions(audio: true), ready: Bool = true) -> Task<PublishState, Error> {
        Task { try await controller.start(options, media: media, ready: ready, send: { [unowned self] frame in
            frames.append(frame)
            if frame["type"] == throwFrameType.map(JSONValue.string) { throw FakeFailure.negotiation }
            return true
        }) }
    }
    func starting(_ options: PublishOptions = PublishOptions(audio: true)) async -> Task<PublishState, Error> {
        let task = start(options)
        await settle { self.controller.state.phase == .starting }
        return task
    }
    func signal(_ state: String, reason: JSONValue? = nil, id: String? = nil) async throws {
        var object: [String: JSONValue] = ["type": .string("publishState"),
            "mediaSessionId": .string(id ?? self.id), "state": .string(state)]
        object["reason"] = reason
        controller.receive(String(decoding: try JSONEncoder().encode(object), as: UTF8.self))
        await drain()
    }
}

@Suite @MainActor struct PublishTests {
    @Test func acceptancePrecedesAllCaptureAndActiveWaitsForAttachments() async throws {
        let h = PublishHarness()
        let task = await h.starting(PublishOptions(audio: true, video: true))
        #expect(h.media.captures.isEmpty)
        #expect(!h.media.next.starting)
        #expect(h.media.next.attachments.isEmpty)
        #expect(h.frames == [["type": .string("publishStart"), "mediaSessionId": .string(h.id),
                              "kinds": .array([.string("audio"), .string("video")])]])
        #expect(UUID(uuidString: h.id) != nil)
        try await h.signal("accepted")
        #expect(h.controller.state.phase == .capturing)
        #expect(h.media.next.attachments == [.audio, .video])
        try await h.signal("accepted")
        try await h.signal("active")
        let result = try await task.value
        try await h.signal("active")
        #expect(result.phase == .active)
        #expect(h.snapshots.map(\.phase) == [.starting, .accepted, .capturing, .active])
        #expect(h.media.next.attachments == [.audio, .video])
        #expect(h.clock.pendingCount == 0)
        h.controller.stop()
        #expect(h.media.next.stopped)
        #expect(h.frames.last == ["type": .string("stopPublish"), "mediaSessionId": .string(result.mediaSessionId!)])
        #expect(h.failures.isEmpty)
    }
    @Test func activeImpliesAcceptance() async throws {
        let h = PublishHarness()
        let task = await h.starting()
        try await h.signal("active")
        #expect(try await task.value.phase == .active)
        #expect(h.media.next.attachments == [.audio])
        h.controller.stop()
    }
    @Test(arguments: [
        ("forbidden", PublishFailureReason.publishNotAllowed), ("unsupported", .publishUnsupported),
        ("busy", .publishBusy), ("inject_failed", .publishFailed), ("source_lost", .publishFailed),
        ("connection_closed", .disconnected), ("new_reason", .publishFailed)
    ])
    func serverReasonsTerminateWithoutAffectingViewer(reason: String, expected: PublishFailureReason) async throws {
        let h = PublishHarness()
        let task = await h.starting()
        try await h.signal("rejected", reason: .string(reason))
        await #expect(throws: PublishFailure(reason: expected, serverReason: reason)) { try await task.value }
        #expect(h.controller.state.reason == expected.rawValue)
        #expect(h.controller.state.serverReason == reason)
        #expect(h.media.captures.isEmpty)
        #expect(!h.media.next.starting)
        #expect(h.media.next.attachments.isEmpty)
        #expect(h.failures.count == 1)
        #expect(h.clock.pendingCount == 0)
    }
    @Test func silenceHasExactResponseDeadlineAndNeverMeansForbidden() async throws {
        let h = PublishHarness()
        let task = await h.starting()
        let id = h.id
        h.clock.advance(to: 4_999)
        #expect(h.controller.state.phase == .starting)
        h.clock.advance(to: 5_000)
        await #expect(throws: PublishFailure(reason: .publishUnsupported, detail: "response_timeout")) { try await task.value }
        try await h.signal("active", id: id)
        #expect(h.controller.state.detail == "response_timeout")
        #expect(h.media.captures.isEmpty)
        #expect(!h.media.next.starting)
        #expect(h.media.next.attachments.isEmpty)
        #expect(h.frames.last?["type"] == .string("stopPublish"))
        #expect(h.failures.count == 1)
    }
    @Test func acceptanceReplacesDeadlineAndDuplicatesCannotExtendIt() async throws {
        let h = PublishHarness()
        let task = await h.starting()
        h.clock.advance(to: 4_999)
        try await h.signal("accepted")
        h.clock.advance(to: 34_998)
        try await h.signal("accepted")
        #expect(h.controller.state.phase == .capturing)
        h.clock.advance(to: 34_999)
        await #expect(throws: PublishFailure(reason: .publishTimeout, detail: "active_timeout")) { try await task.value }
        #expect(h.media.next.stopped)
        #expect(h.clock.pendingCount == 0)
    }
    @Test func malformedForeignAndUnknownFramesAreIgnored() async throws {
        let h = PublishHarness()
        let task = await h.starting()
        h.controller.receive("{bad")
        h.controller.receive("{\"type\":\"publishState\",\"mediaSessionId\":7,\"state\":\"active\"}")
        try await h.signal("active", id: "another-operation")
        try await h.signal("future_state")
        #expect(h.controller.state.phase == .starting)
        try await h.signal("rejected", reason: .number(7))
        await #expect(throws: PublishFailure(reason: .publishFailed)) { try await task.value }
        #expect(h.controller.state.serverReason == nil)
    }
    @Test func captureDeniedAfterAcceptanceStopsOriginalSession() async throws {
        let h = PublishHarness()
        h.media.next.failure = PublishFailure(reason: .permissionDenied, detail: "capture_permission")
        let task = await h.starting()
        let id = h.id
        #expect(h.media.captures.isEmpty)
        try await h.signal("accepted")
        await #expect(throws: PublishFailure(reason: .permissionDenied, detail: "capture_permission")) { try await task.value }
        #expect(h.media.next.stopped)
        #expect(h.failures.count == 1)
        #expect(h.frames.last == ["type": .string("stopPublish"), "mediaSessionId": .string(id)])
    }
    @Test func cancelDuringPermissionWaitStopsImmediatelyAndLateCaptureIsInert() async throws {
        let h = PublishHarness()
        h.media.next.holdStart = true
        let task = await h.starting()
        try await h.signal("accepted")
        await settle { h.media.next.gate != nil }
        h.controller.stop()
        #expect(h.media.next.stopped)
        await #expect(throws: PublishFailure(reason: .publishCancelled)) { try await task.value }
        h.media.next.finishStart()
        await drain()
        #expect(h.controller.state.phase == .stopped)
        #expect(h.controller.state.reason == "stopped_by_client")
        #expect(h.media.next.attachments.isEmpty)
        #expect(h.frames.map { $0["type"] } == [.string("publishStart"), .string("stopPublish")])
        #expect(h.failures.isEmpty)
    }
    @Test func taskCancellationStopsItsOwnOperation() async {
        let h = PublishHarness()
        let task = await h.starting()
        try? await h.signal("accepted")
        task.cancel()
        await #expect(throws: PublishFailure(reason: .publishCancelled)) { try await task.value }
        #expect(h.media.next.stopped)
        #expect(h.controller.state.phase == .stopped)
        #expect(h.failures.isEmpty)
    }
    @Test func failedVideoAttachmentReleasesAudioToo() async throws {
        let h = PublishHarness()
        h.media.next.failVideoAttach = true
        let task = await h.starting(PublishOptions(audio: true, video: true))
        try await h.signal("accepted")
        await #expect(throws: PublishFailure(reason: .publishFailed, detail: "attach_failed")) { try await task.value }
        #expect(h.media.next.attachments == [.audio])
        #expect(h.media.next.stopped)
        #expect(h.frames.last?["type"] == .string("stopPublish"))
    }
    @Test func secondPendingStartLeavesExistingOperationUntouched() async throws {
        let h = PublishHarness()
        let first = await h.starting()
        let id = h.id
        let second = h.start()
        await #expect(throws: PublishFailure(reason: .publishFailed, detail: "publish_in_progress")) { try await second.value }
        #expect(h.id == id)
        #expect(h.media.captures.isEmpty)
        #expect(h.frames.count == 1)
        #expect(!h.media.next.stopped)
        h.controller.stop()
        _ = await first.result
    }
    @Test func secondActiveStartLeavesExistingOperationUntouched() async throws {
        let h = PublishHarness()
        let first = await h.starting()
        let id = h.id
        try await h.signal("active")
        _ = try await first.value
        let second = h.start()
        await #expect(throws: PublishFailure(reason: .publishFailed, detail: "already_publishing")) { try await second.value }
        #expect(h.id == id)
        #expect(h.controller.state.phase == .active)
        #expect(h.media.captures.count == 1)
        #expect(h.frames.count == 1)
        #expect(!h.media.next.stopped)
        h.controller.stop()
    }
    @Test(arguments: [false, true])
    func audioIsRequiredBeforeCaptureOrSignaling(video: Bool) async {
        let h = PublishHarness()
        let task = h.start(PublishOptions(audio: false, video: video))
        await #expect(throws: PublishFailure(reason: .publishFailed, detail: "invalid_options")) { try await task.value }
        #expect(h.media.captures.isEmpty)
        #expect(h.frames.isEmpty)
    }
    @Test func missingCapabilityFailsBeforeCapture() async {
        let h = PublishHarness(capabilities: nil)
        let task = h.start()
        await #expect(throws: PublishFailure(reason: .publishUnsupported, detail: "capabilities_unavailable")) { try await task.value }
        #expect(h.media.captures.isEmpty)
        #expect(h.frames.isEmpty)
    }
    @Test(arguments: [
        DevicePublishCapabilities(microphoneInjection: false, cameraInjection: true, mediaInjectionTransport: "direct"),
        DevicePublishCapabilities(microphoneInjection: true, cameraInjection: false, mediaInjectionTransport: "relay")
    ])
    func incompatibleCapabilityFailsBeforeCapture(capabilities: DevicePublishCapabilities) async {
        let h = PublishHarness(capabilities: capabilities)
        let task = h.start()
        await #expect(throws: PublishFailure(reason: .publishUnsupported, detail: "device_capability")) { try await task.value }
        #expect(h.media.captures.isEmpty)
    }
    @Test func cameraSupportDoesNotGateAudio() async throws {
        let h = PublishHarness()
        h.media.supportsPublishCamera = false
        let camera = h.start(PublishOptions(audio: true, video: true))
        await #expect(throws: PublishFailure(reason: .publishUnsupported, detail: "local_media_support")) { try await camera.value }
        #expect(h.media.captures.isEmpty)
        let audio = await h.starting()
        try await h.signal("active")
        #expect(try await audio.value.kinds == [.audio])
        h.controller.stop()
    }
    @Test func readinessIsCheckedBeforePermissions() async {
        let h = PublishHarness()
        let task = h.start(ready: false)
        await #expect(throws: PublishFailure(reason: .disconnected, detail: "not_connected")) { try await task.value }
        #expect(h.media.captures.isEmpty)
    }
    @Test func activeSourceLossTerminatesEntireSessionOnce() async throws {
        let h = PublishHarness()
        let task = await h.starting(PublishOptions(audio: true, video: true))
        try await h.signal("active")
        _ = try await task.value
        h.media.next.onEnded?()
        h.controller.disconnect()
        #expect(h.controller.state.reason == "publish_failed")
        #expect(h.controller.state.detail == "capture_unavailable")
        #expect(h.media.next.stopped)
        #expect(h.failures.count == 1)
    }
    @Test func disconnectCleansCaptureAndExplicitRestartUsesNewUUID() async {
        let h = PublishHarness()
        let task = await h.starting()
        let oldID = h.id
        try? await h.signal("accepted")
        h.controller.disconnect()
        await #expect(throws: PublishFailure(reason: .disconnected)) { try await task.value }
        #expect(h.media.next.stopped)
        #expect(h.clock.pendingCount == 0)
        h.media.next = FakePublishCapture()
        let next = await h.starting()
        #expect(h.id != oldID)
        #expect(h.controller.state.reason == nil)
        h.controller.stop()
        _ = await next.result
    }
    @Test func closedControllerRejectsWithoutObserverCallbacks() async {
        let h = PublishHarness()
        h.controller.close()
        let task = h.start()
        await #expect(throws: PublishFailure(reason: .disconnected, detail: "session_closed")) { try await task.value }
        #expect(h.snapshots.isEmpty)
        #expect(h.failures.isEmpty)
    }
    @Test func lateCancelledCaptureCannotAffectNextOperation() async throws {
        let h = PublishHarness()
        let old = h.media.next
        old.holdStart = true
        let first = await h.starting()
        try await h.signal("accepted")
        await settle { old.gate != nil }
        h.controller.stop()
        _ = await first.result
        h.media.next = FakePublishCapture()
        let next = await h.starting()
        let id = h.id
        old.finishStart()
        await drain()
        #expect(old.stopped)
        #expect(old.attachments.isEmpty)
        #expect(!h.media.next.stopped)
        #expect(h.frames.map { $0["type"] } == [.string("publishStart"), .string("stopPublish"), .string("publishStart")])
        try await h.signal("active", id: id)
        #expect(try await next.value.phase == .active)
        h.controller.stop()
    }
    @Test(arguments: ["stopped", "error"])
    func unexpectedTerminalStopsActiveCapture(state: String) async throws {
        let h = PublishHarness()
        let task = await h.starting()
        try await h.signal("active")
        _ = try await task.value
        let id = h.id
        try await h.signal(state, reason: .string("stopped_by_client"))
        try await h.signal(state, reason: .string("stopped_by_client"), id: id)
        #expect(h.controller.state.reason == "publish_failed")
        #expect(h.controller.state.detail == "remote_stop")
        #expect(h.media.next.stopped)
        #expect(h.failures.count == 1)
    }
    @Test func stopIsIdempotentAndPreservesTerminalSnapshot() async {
        let h = PublishHarness()
        let task = await h.starting()
        h.controller.stop()
        let state = h.controller.state
        h.controller.stop()
        _ = await task.result
        #expect(h.controller.state == state)
        #expect(h.frames.count == 2)
        #expect(h.snapshots.map(\.phase) == [.starting, .stopped])
    }
    @Test(arguments: [
        (false, false, false), (true, false, true), (true, true, false)
    ])
    func pillVisibility(capable: Bool, hidden: Bool, expected: Bool) {
        let caps = capable ? DevicePublishCapabilities(microphoneInjection: true, cameraInjection: true, mediaInjectionTransport: "direct") : nil
        let presentation = PublishPresentation(capabilities: caps, cameraSupported: true, shown: !hidden, phase: .starting)
        #expect(presentation.visible == expected)
        #expect(presentation.cameraVisible == expected)
        #expect(presentation.starting)
    }
    @Test func acceptedPermissionWaitHasThirtySecondDeadlineEvenWhenActiveArrivesEarly() async throws {
        let h = PublishHarness()
        h.media.next.holdStart = true
        let task = await h.starting()
        try await h.signal("active")
        #expect(h.media.next.gate != nil)
        #expect(h.controller.state.phase == .capturing)
        h.clock.advance(to: 29_999)
        #expect(h.controller.state.phase == .capturing)
        h.clock.advance(to: 30_000)
        await #expect(throws: PublishFailure(reason: .publishTimeout, detail: "active_timeout")) { try await task.value }
        #expect(h.media.next.stopped)
        h.media.next.finishStart()
        await drain()
        #expect(h.media.next.attachments.isEmpty)
        #expect(h.frames.last?["type"] == .string("stopPublish"))
    }
    @Test func activeDuringPermissionWaitLatchesUntilCaptureCompletes() async throws {
        let h = PublishHarness()
        h.media.next.holdStart = true
        let task = await h.starting()
        try await h.signal("accepted")
        try await h.signal("active")
        #expect(h.controller.state.phase == .capturing)
        #expect(h.media.captures.count == 1)
        #expect(h.media.next.attachments.isEmpty)
        h.media.next.finishStart()
        #expect(try await task.value.phase == .active)
        #expect(h.media.next.attachments == [.audio])
        #expect(h.clock.pendingCount == 0)
        h.controller.stop()
    }
    @Test func throwingStartSendIsDisconnectedWithoutCapture() async {
        let h = PublishHarness()
        h.throwFrameType = "publishStart"
        let task = h.start()
        await #expect(throws: PublishFailure(reason: .disconnected)) { try await task.value }
        #expect(h.controller.state.reason == "disconnected")
        #expect(h.failures.map(\.reason) == [.disconnected])
        #expect(h.media.captures.isEmpty)
        #expect(h.clock.pendingCount == 0)
        #expect(h.frames.map { $0["type"] } == [.string("publishStart")])
    }
    @Test func throwingStopSendReleasesCaptureAndReportsDisconnectedOnce() async throws {
        let h = PublishHarness()
        let task = await h.starting()
        try await h.signal("active")
        _ = try await task.value
        h.throwFrameType = "stopPublish"
        h.controller.stop()
        h.controller.stop()
        #expect(h.media.next.stopped)
        #expect(h.controller.state.reason == "disconnected")
        #expect(h.failures.map(\.reason) == [.disconnected])
        #expect(h.clock.pendingCount == 0)
    }
    @Test func stopBeforeAcceptanceNeverCaptures() async {
        let h = PublishHarness()
        let task = await h.starting()
        h.controller.stop()
        await #expect(throws: PublishFailure(reason: .publishCancelled)) { try await task.value }
        #expect(h.media.captures.isEmpty)
        #expect(h.failures.isEmpty)
        #expect(h.controller.state.phase == .stopped)
    }
    @Test func unsupportedPublishHidesPillRatherThanAddingALabelKey() {
        let caps = DevicePublishCapabilities(microphoneInjection: true, cameraInjection: true, mediaInjectionTransport: "direct")
        let presentation = PublishPresentation(capabilities: caps, cameraSupported: true, shown: true,
                                              phase: .error, reason: "publish_unsupported")
        #expect(!presentation.visible)
        #expect(!presentation.cameraVisible)
    }
    @Test func defaultPublishLabelsMatchSharedContract() {
        let labels = StreamLabels()
        #expect(labels.microphone == "Microphone")
        #expect(labels.camera == "Camera")
        #expect(labels.stopMicrophone == "Stop microphone")
        #expect(labels.stopCamera == "Stop camera")
        #expect(labels.publishStarting == "Starting inputs")
        #expect(labels.publishPermissionDenied == "Microphone or camera permission denied")
        #expect(labels.publishFailed == "Could not publish inputs")
        #expect(labels.publishNotAllowed == "Publishing is not allowed")
    }
    @Test(arguments: [
        (PublishFailureReason.publishNotAllowed, "Publishing is not allowed"),
        (.publishUnsupported, "Inputs are not supported on this device"),
        (.permissionDenied, "Microphone or camera permission denied"),
        (.publishBusy, "Inputs are already in use"), (.publishFailed, "Could not publish inputs"),
        (.publishTimeout, "Publishing inputs timed out"), (.publishCancelled, "Publishing inputs was cancelled"),
        (.disconnected, "Device stream disconnected")
    ])
    func failureMessageDescribesReason(reason: PublishFailureReason, expected: String) {
        #expect(PublishFailure(reason: reason).message == expected)
    }
    @Test(arguments: [
        ("42e01f", true), ("42e034", true), ("42C020", true), ("4d0029", true), ("640c34", true),
        ("42e01e", false), ("640c0b", false), ("dead34", false), ("42e0xx", false), ("42e01ff", false)
    ])
    func h264AcceptsSupportedProfileAtAnyLevelAtLeast31(profile: String, expected: Bool) {
        #expect(CodecPreferences.supportsPublishH264Profile(profile) == expected)
    }
    @Test func existingInitializerFunctionReferencesRemainAvailable() {
        let config = StreamConfig.init(muted:videoCodec:)
        let labels = StreamLabels.init(connecting:reconnecting:reconnectingAttempt:disconnected:unavailable:retry:back:home:recent:)
        let error = StreamConnectionError.init(reason:message:attempt:final:)
        #expect(config(false, .automatic).publishCapabilities == nil)
        #expect(labels("c", "r", "ra", "d", "u", "retry", "b", "h", "recent").microphone == "Microphone")
        #expect(error(.disconnected, "d", 1, true).operation == nil)
    }
    @Test func labelsAreOverridableForPublishFailures() {
        let labels = StreamLabels(microphone: "M", camera: "C", publishStarting: "S",
                                  publishPermissionDenied: "P", publishNotAllowed: "N", publishFailed: "F")
        #expect(labels.microphone == "M")
        #expect(labels.camera == "C")
        #expect(labels.publishLabel(PublishState(phase: .capturing)) == "S")
        #expect(labels.publishLabel(PublishState(phase: .error, reason: "permission_denied")) == "P")
        #expect(labels.publishLabel(PublishState(phase: .error, reason: "publish_not_allowed")) == "N")
        #expect(labels.publishLabel(PublishState(phase: .error, reason: "publish_failed")) == "F")
    }
}

@Suite @MainActor struct PublishSessionTests {
    @Test func forbiddenUsesPublishErrorEnvelopeAndViewerStaysConnected() async throws {
        let h = try SessionHarness()
        h.publishCapabilities = DevicePublishCapabilities(microphoneInjection: true, cameraInjection: true, mediaInjectionTransport: "direct")
        try await h.connected()
        defer { h.engine.close() }
        var errors: [StreamConnectionError] = []
        h.engine.onError = { errors.append($0) }
        let task = Task { try await h.engine.startPublish(PublishOptions(audio: true)) }
        await settle { !h.sockets[0].frames("publishStart").isEmpty }
        let id = h.sockets[0].frames("publishStart")[0].1["mediaSessionId"]!
        try h.sockets[0].receive(["type": .string("publishState"), "mediaSessionId": id,
                                  "state": .string("rejected"), "reason": .string("forbidden")])
        await #expect(throws: PublishFailure(reason: .publishNotAllowed, serverReason: "forbidden")) { try await task.value }
        #expect(h.engine.status == .connected)
        #expect(errors.count == 1)
        #expect(errors.first?.reason == .publishNotAllowed)
        #expect(errors.first?.operation == "publish")
        #expect(errors.first?.serverReason == "forbidden")
        #expect(errors.first?.attempt == 0)
        #expect(errors.first?.final == true)
        #expect(errors.first?.mediaSessionId == id.stringValue)
        #expect(h.peers[0].publishMedia.captures.isEmpty)
        #expect(!h.peers[0].publishMedia.next.starting)
        #expect(h.peers[0].publishMedia.next.attachments.isEmpty)
        #expect(!h.peers[0].closed)
    }
    @Test func throwingSignalingTransportPropagatesDisconnectedPublishFailure() async throws {
        let h = try SessionHarness()
        h.publishCapabilities = DevicePublishCapabilities(microphoneInjection: true, cameraInjection: false, mediaInjectionTransport: "direct")
        try await h.connected()
        defer { h.engine.close() }
        var errors: [StreamConnectionError] = []
        h.engine.onError = { errors.append($0) }
        h.sockets[0].throwFrameType = "publishStart"
        await #expect(throws: PublishFailure(reason: .disconnected)) {
            try await h.engine.startPublish(PublishOptions(audio: true))
        }
        #expect(errors.map(\.reason) == [.disconnected])
        #expect(errors.first?.operation == "publish")
        #expect(h.peers[0].publishMedia.captures.isEmpty)
        #expect(h.engine.publisher.state.reason == "disconnected")
    }
    @Test func asynchronousStopWriteFailureReportsDisconnectedAfterLocalTeardown() async throws {
        let h = try SessionHarness()
        h.publishCapabilities = DevicePublishCapabilities(microphoneInjection: true, cameraInjection: false, mediaInjectionTransport: "direct")
        try await h.connected()
        defer { h.engine.close() }
        var errors: [StreamConnectionError] = []
        h.engine.onError = { errors.append($0) }
        let task = Task { try await h.engine.startPublish(PublishOptions(audio: true)) }
        await settle { !h.sockets[0].frames("publishStart").isEmpty }
        let id = h.sockets[0].frames("publishStart")[0].1["mediaSessionId"]!
        try h.sockets[0].receive(["type": .string("publishState"), "mediaSessionId": id, "state": .string("active")])
        _ = try await task.value
        h.engine.publisher.stop()
        #expect(h.engine.publisher.state.phase == .stopped)
        #expect(h.peers[0].publishMedia.next.stopped)
        let failWrite = try #require(h.sockets[0].publishWriteFailures["stopPublish"])
        failWrite()
        failWrite()
        #expect(h.engine.publisher.state.reason == "disconnected")
        #expect(errors.map(\.reason) == [.disconnected])
        #expect(errors.first?.operation == "publish")
        #expect(errors.first?.mediaSessionId == id.stringValue)
    }
    @Test func socketLossStopsPublicationAndReconnectDoesNotResume() async throws {
        let h = try SessionHarness()
        h.publishCapabilities = DevicePublishCapabilities(microphoneInjection: true, cameraInjection: false, mediaInjectionTransport: "direct")
        try await h.connected()
        defer { h.engine.close() }
        let task = Task { try await h.engine.startPublish(PublishOptions(audio: true)) }
        await settle { !h.sockets[0].frames("publishStart").isEmpty }
        let id = h.sockets[0].frames("publishStart")[0].1["mediaSessionId"]!
        try h.sockets[0].receive(["type": .string("publishState"), "mediaSessionId": id, "state": .string("active")])
        _ = try await task.value
        h.sockets[0].onEvent?(.closed)
        #expect(h.peers[0].publishMedia.next.stopped)
        #expect(h.engine.publisher.state.reason == "disconnected")
        h.clock.advance(to: 1_000)
        await settle { h.sockets.count == 2 }
        h.sockets[1].onEvent?(.opened)
        try h.sockets[1].receive(h.object("server-rtc-configuration"))
        await settle { h.peers.count == 2 && !h.sockets[1].frames("offer").isEmpty }
        h.peers[1].onEvent?(.state(.connected))
        await drain()
        #expect(h.sockets[1].frames("publishStart").isEmpty)
        #expect(h.sockets[1].frames("stopPublish").isEmpty)
        #expect(h.peers[1].publishMedia.captures.isEmpty)
    }
    @Test func failedIceRefreshEndsPublicationAtGraceDeadline() async throws {
        let h = try SessionHarness()
        h.publishCapabilities = DevicePublishCapabilities(microphoneInjection: true, cameraInjection: false, mediaInjectionTransport: "direct")
        try await h.connected()
        defer { h.engine.close() }
        let task = Task { try await h.engine.startPublish(PublishOptions(audio: true)) }
        await settle { !h.sockets[0].frames("publishStart").isEmpty }
        let id = h.sockets[0].frames("publishStart")[0].1["mediaSessionId"]!
        try h.sockets[0].receive(["type": .string("publishState"), "mediaSessionId": id, "state": .string("active")])
        _ = try await task.value
        try h.sockets[0].receive(h.sequenceMessage("refresh", step: 1))
        await settle { h.peers[0].restarts.count == 2 }
        h.peers[0].onEvent?(.state(.disconnected))
        h.clock.advance(to: 14_999)
        #expect(!h.peers[0].publishMedia.next.stopped)
        h.clock.advance(to: 15_000)
        #expect(h.peers[0].publishMedia.next.stopped)
        #expect(h.engine.publisher.state.reason == "disconnected")
    }
    @Test func samePeerIceRefreshKeepsPublicationAndUUID() async throws {
        let h = try SessionHarness()
        h.publishCapabilities = DevicePublishCapabilities(microphoneInjection: true, cameraInjection: false, mediaInjectionTransport: "direct")
        try await h.connected()
        defer { h.engine.close() }
        let task = Task { try await h.engine.startPublish(PublishOptions(audio: true)) }
        await settle { !h.sockets[0].frames("publishStart").isEmpty }
        let id = h.sockets[0].frames("publishStart")[0].1["mediaSessionId"]!
        try h.sockets[0].receive(["type": .string("publishState"), "mediaSessionId": id, "state": .string("active")])
        _ = try await task.value
        try h.sockets[0].receive(h.sequenceMessage("refresh", step: 1))
        await settle { h.peers[0].restarts.count == 2 }
        h.peers[0].onEvent?(.state(.disconnected))
        #expect(h.engine.publisher.state.phase == .active)
        #expect(h.engine.publisher.state.mediaSessionId == id.stringValue)
        #expect(h.sockets[0].frames("publishStart").count == 1)
        #expect(!h.peers[0].publishMedia.next.stopped)
        h.peers[0].onEvent?(.state(.connected))
    }
}

#if os(iOS)
import SwiftUI
import UIKit

@Suite(.serialized) @MainActor struct NativePublishTests {
    @Test func nativeTracklessOfferHasSeparateOrderedReservations() async throws {
        let caps = DevicePublishCapabilities(microphoneInjection: true, cameraInjection: true, mediaInjectionTransport: "direct")
        let peer = WebRTCPeer(config: StreamConfig(publishCapabilities: caps), startedAt: 0,
                              onTrack: { _ in }, onSize: { _ in })
        defer { peer.close() }
        guard case .message(.rtcConfiguration(let config)) = ServerMessage.parse(
            "{\"type\":\"rtcConfiguration\",\"rtcConfiguration\":{\"iceServers\":[]}}", phase: .awaitingRTCConfiguration) else {
            Issue.record("invalid fixture"); return
        }
        try peer.configure(config, channels: [])
        let sdp = try await peer.createOffer(iceRestart: false)
        let media = sdp.components(separatedBy: "m=").dropFirst().map { $0.components(separatedBy: "\r\n") }
        #expect(media[0][0].hasPrefix("audio "))
        #expect(media[0].contains("a=recvonly"))
        #expect(media[1][0].hasPrefix("video "))
        #expect(media[1].contains("a=recvonly"))
        #expect(media.last?[0].hasPrefix("audio ") == true)
        #expect(media.last?.contains("a=sendonly") == true)
        #expect(PublishSDP.hasReservation(sdp, kind: .audio))
        #expect(peer.supportsPublishReservations)
        #expect(sdp.contains("opus/48000/2"))
        #expect(peer.supportsPublishCamera == PublishSDP.hasReservation(sdp, kind: .video))
        #expect(peer.supportsPublishCamera == WebRTCPeer.cameraEncoderSupported)
        #expect(peer.supportsPublishCamera)
        #expect(media[2].contains("a=sendonly"))
        #expect(media[2].contains(where: { $0.contains("profile-level-id=42e0") && $0.contains("level-asymmetry-allowed=1") }))
        #expect(media[2].contains(where: { $0.contains("packetization-mode=1") }))
    }
    @Test(arguments: [375, 1280])
    func pillOverlayPreservesVideoSurface(width: Int) async throws {
        let session = DeviceStreamSession(credentials: { nil }, config: StreamConfig(publishCapabilities:
            DevicePublishCapabilities(microphoneInjection: true, cameraInjection: true, mediaInjectionTransport: "direct")))
        session.presentForTesting(.connected)
        defer { session.close() }
        let bounds = CGRect(x: 0, y: 0, width: width, height: 720)
        func stream(_ shown: Bool) -> some View {
            DeviceStream(session: session, showsNavigation: false, showsPublishControls: shown)
                .streamTheme(.dark.with { $0.surfaceStyle = .solid }).ignoresSafeArea()
        }
        let host = UIHostingController(rootView: stream(false))
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = bounds
        host.view.layoutIfNeeded()
        await drain()
        let before = try #require(Self.surface(host.view))
        let originalBounds = before.bounds
        host.rootView = stream(true)
        host.view.layoutIfNeeded()
        await drain()
        host.view.layoutIfNeeded()
        let after = try #require(Self.surface(host.view))
        #expect(before === after)
        #expect(after.bounds == originalBounds)
        #expect(after.bounds.width == CGFloat(width))
        #expect(after.bounds.height == 720)
    }
    private static func surface(_ view: UIView) -> DeviceStreamUIView? {
        if let surface = view as? DeviceStreamUIView { return surface }
        return view.subviews.lazy.compactMap { surface($0) }.first
    }
    private func activeSession() async throws -> (SessionHarness, DeviceStreamSession) {
        let h = try SessionHarness()
        h.publishCapabilities = DevicePublishCapabilities(microphoneInjection: true, cameraInjection: true, mediaInjectionTransport: "direct")
        let session = DeviceStreamSession(engine: h.engine, videoSize: VideoSize(width: 640, height: 1280))
        try await h.connected()
        let task = Task { try await session.startPublish(PublishOptions(audio: true)) }
        await settle { !h.sockets[0].frames("publishStart").isEmpty }
        let id = h.sockets[0].frames("publishStart")[0].1["mediaSessionId"]!
        try h.sockets[0].receive(["type": .string("publishState"), "mediaSessionId": id, "state": .string("active")])
        _ = try await task.value
        return (h, session)
    }
    @Test func headlessSessionStopsOnBackgroundWithoutLifecycleAdapter() async throws {
        let (h, session) = try await activeSession()
        defer { session.close() }
        var errors: [StreamConnectionError] = []
        session.onError = { errors.append($0) }
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await settle { session.publishState.phase == .stopped }
        #expect(h.peers[0].publishMedia.next.stopped)
        #expect(errors.isEmpty)
        #expect(h.sockets[0].frames("stopPublish").count == 1)
    }
    @Test func rendererRemountEndsPublicationWithOneDisconnectedEvent() async throws {
        let (h, session) = try await activeSession()
        defer { session.close() }
        var errors: [StreamConnectionError] = []
        session.onError = { errors.append($0) }
        let view = DeviceStreamUIView(session: session, hasControl: true)
        view.detach()
        view.detach()
        #expect(session.publishState.reason == "disconnected")
        #expect(session.publishState.phase == .error)
        #expect(h.peers[0].publishMedia.next.stopped)
        #expect(errors.map(\.reason) == [.disconnected])
        #expect(errors.first?.operation == "publish")
        #expect(h.engine.status == .connected)
    }
    @Test func rendererReplacementDisconnectsOldSessionOnce() async throws {
        let (h, session) = try await activeSession()
        let replacement = DeviceStreamSession(credentials: { nil })
        defer { session.close(); replacement.close() }
        var errors: [StreamConnectionError] = []
        session.onError = { errors.append($0) }
        let view = DeviceStreamUIView(session: session, hasControl: true)
        view.update(session: replacement, hasControl: true)
        view.detach()
        #expect(session.publishState.reason == "disconnected")
        #expect(h.peers[0].publishMedia.next.stopped)
        #expect(errors.map(\.reason) == [.disconnected])
        #expect(replacement.publishState.phase == .idle)
    }
    @Test func pillFadesAtThreeSecondsAndInteractionRestartsDeadline() {
        let clock = FakeClock()
        let interaction = PublishPillInteraction(scheduler: clock)
        interaction.interact()
        clock.advance(to: 2_999)
        #expect(interaction.opacity == 1)
        clock.advance(to: 3_000)
        #expect(interaction.opacity == 0.5)
        interaction.interact()
        #expect(interaction.opacity == 1)
        clock.advance(to: 5_999)
        #expect(interaction.opacity == 1)
        clock.advance(to: 6_000)
        #expect(interaction.opacity == 0.5)
        interaction.interact()
        interaction.stop()
        clock.advance(to: 20_000)
        #expect(interaction.opacity == 1)
        #expect(clock.pendingCount == 0)
    }
    @Test func proximityObserverDoesNotOwnHitsAndOnlyRestoresNearbyInteraction() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let probe = PublishPillProximity.ProximityView()
        probe.frame = CGRect(x: 100, y: 600, width: 110, height: 56)
        var restored = 0
        probe.onInteraction = { restored += 1 }
        window.addSubview(probe)
        #expect(!probe.isUserInteractionEnabled)
        #expect(probe.hitTest(CGPoint(x: 20, y: 20), with: nil) == nil)
        probe.observe(CGPoint(x: 90, y: 590))
        #expect(restored == 1)
        probe.observe(CGPoint(x: 50, y: 500))
        #expect(restored == 1)
        probe.unbind()
        probe.observe(CGPoint(x: 120, y: 620))
        #expect(restored == 1)
    }
    @Test func missingUsageDescriptionsFailBeforeProtectedCapture() async {
        let capture = NativePublishCapture(options: PublishOptions(audio: true, video: true), audio: nil, video: nil, usageDescription: { _ in nil })
        await #expect(throws: PublishFailure(reason: .publishFailed, detail: "capture_configuration")) { try await capture.start() }
        capture.stop()
    }
}
#endif
