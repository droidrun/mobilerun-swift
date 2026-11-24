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
            return true
        }) }
    }
    func starting(_ options: PublishOptions = PublishOptions(audio: true)) async -> Task<PublishState, Error> {
        let task = start(options)
        await settle { self.controller.state.phase == .starting }
        return task
    }
    func signal(_ state: String, reason: JSONValue? = nil, id: String? = nil) throws {
        var object: [String: JSONValue] = ["type": .string("publishState"),
            "mediaSessionId": .string(id ?? self.id), "state": .string(state)]
        object["reason"] = reason
        controller.receive(String(decoding: try JSONEncoder().encode(object), as: UTF8.self))
    }
}

@Suite @MainActor struct PublishTests {
    @Test func acceptedThenActiveAttachesInOrderAndResolvesOnlyActive() async throws {
        let h = PublishHarness()
        let task = await h.starting(PublishOptions(audio: true, video: true))
        #expect(h.media.next.attachments.isEmpty)
        #expect(h.frames == [["type": .string("publishStart"), "mediaSessionId": .string(h.id),
                              "kinds": .array([.string("audio"), .string("video")])]])
        #expect(UUID(uuidString: h.id) != nil)
        try h.signal("accepted")
        #expect(h.controller.state.phase == .accepted)
        #expect(h.media.next.attachments == [.audio, .video])
        try h.signal("accepted")
        try h.signal("active")
        let result = try await task.value
        try h.signal("active")
        #expect(result.phase == .active)
        #expect(h.snapshots.map(\.phase) == [.capturing, .starting, .accepted, .active])
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
        try h.signal("active")
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
        try h.signal("rejected", reason: .string(reason))
        await #expect(throws: PublishFailure(reason: expected, serverReason: reason)) { try await task.value }
        #expect(h.controller.state.reason == expected.rawValue)
        #expect(h.controller.state.serverReason == reason)
        #expect(h.media.next.stopped)
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
        try h.signal("active", id: id)
        #expect(h.controller.state.detail == "response_timeout")
        #expect(h.media.next.stopped)
        #expect(h.media.next.attachments.isEmpty)
        #expect(h.frames.last?["type"] == .string("stopPublish"))
        #expect(h.failures.count == 1)
    }
    @Test func acceptanceReplacesDeadlineAndDuplicatesCannotExtendIt() async throws {
        let h = PublishHarness()
        let task = await h.starting()
        h.clock.advance(to: 4_999)
        try h.signal("accepted")
        h.clock.advance(to: 19_998)
        try h.signal("accepted")
        #expect(h.controller.state.phase == .accepted)
        h.clock.advance(to: 19_999)
        await #expect(throws: PublishFailure(reason: .publishTimeout, detail: "active_timeout")) { try await task.value }
        #expect(h.media.next.stopped)
        #expect(h.clock.pendingCount == 0)
    }
    @Test func malformedForeignAndUnknownFramesAreIgnored() async throws {
        let h = PublishHarness()
        let task = await h.starting()
        h.controller.receive("{bad")
        h.controller.receive("{\"type\":\"publishState\",\"mediaSessionId\":7,\"state\":\"active\"}")
        try h.signal("active", id: "another-operation")
        try h.signal("future_state")
        #expect(h.controller.state.phase == .starting)
        try h.signal("rejected", reason: .number(7))
        await #expect(throws: PublishFailure(reason: .publishFailed)) { try await task.value }
        #expect(h.controller.state.serverReason == nil)
    }
    @Test func captureDeniedReleasesInputsAndReportsOnce() async {
        let h = PublishHarness()
        h.media.next.failure = PublishFailure(reason: .permissionDenied, detail: "capture_permission")
        let task = h.start()
        await #expect(throws: PublishFailure(reason: .permissionDenied, detail: "capture_permission")) { try await task.value }
        #expect(h.media.next.stopped)
        #expect(h.failures.count == 1)
        #expect(h.frames.isEmpty)
    }
    @Test func cancelDuringPermissionWaitStopsImmediatelyAndLateCaptureIsInert() async {
        let h = PublishHarness()
        h.media.next.holdStart = true
        let task = h.start()
        await settle { h.media.next.gate != nil }
        h.controller.stop()
        #expect(h.media.next.stopped)
        await #expect(throws: PublishFailure(reason: .publishCancelled)) { try await task.value }
        h.media.next.finishStart()
        await drain()
        #expect(h.controller.state.phase == .stopped)
        #expect(h.controller.state.reason == "stopped_by_client")
        #expect(h.media.next.attachments.isEmpty)
        #expect(h.frames.isEmpty)
        #expect(h.failures.isEmpty)
    }
    @Test func taskCancellationStopsItsOwnOperation() async {
        let h = PublishHarness()
        let task = await h.starting()
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
        try h.signal("accepted")
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
        #expect(h.media.captures.count == 1)
        #expect(h.frames.count == 1)
        #expect(!h.media.next.stopped)
        h.controller.stop()
        _ = await first.result
    }
    @Test func secondActiveStartLeavesExistingOperationUntouched() async throws {
        let h = PublishHarness()
        let first = await h.starting()
        let id = h.id
        try h.signal("active")
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
        try h.signal("active")
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
        try h.signal("active")
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
        let first = h.start()
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
        #expect(h.frames.count == 1)
        try h.signal("active", id: id)
        #expect(try await next.value.phase == .active)
        h.controller.stop()
    }
    @Test(arguments: ["stopped", "error"])
    func unexpectedTerminalStopsActiveCapture(state: String) async throws {
        let h = PublishHarness()
        let task = await h.starting()
        try h.signal("active")
        _ = try await task.value
        let id = h.id
        try h.signal(state, reason: .string("stopped_by_client"))
        try h.signal(state, reason: .string("stopped_by_client"), id: id)
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
        #expect(h.snapshots.map(\.phase) == [.capturing, .starting, .stopped])
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
        #expect(h.peers[0].publishMedia.next.stopped)
        #expect(h.peers[0].publishMedia.next.attachments.isEmpty)
        #expect(!h.peers[0].closed)
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
    @Test func missingUsageDescriptionsFailBeforeProtectedCapture() async {
        let capture = NativePublishCapture(options: PublishOptions(audio: true, video: true), audio: nil, video: nil, usageDescription: { _ in nil })
        await #expect(throws: PublishFailure(reason: .publishFailed, detail: "capture_configuration")) { try await capture.start() }
        capture.stop()
    }
}
#endif
