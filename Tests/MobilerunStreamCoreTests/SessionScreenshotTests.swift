// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol
import MobilerunStreamCore
import Testing

@Test("Screenshot success returns decoded image bytes") @MainActor
func sessionScreenshotSuccess() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.negotiate()
    let ws = h.sockets[0]
    let pending = Task { try await h.engine.screenshot() }
    await settle { ws.frames("screenshot").count == 1 }
    try ws.receive([
        "type": .string("screenshot"), "id": ws.frames("screenshot")[0].1["id"]!,
        "dataUri": .string("data:image/png;base64,AQID"),
    ])
    #expect(try await pending.value == Data([1, 2, 3]))
}

enum ScreenshotFailure: CaseIterable, Sendable {
    case timeout, server, malformed, disconnect
    @MainActor func fire(_ h: SessionHarness) throws {
        let id = h.sockets[0].frames("screenshot")[0].1["id"]!
        switch self {
        case .timeout: h.clock.advance(to: 2000)
        case .server:
            try h.sockets[0].receive([
                "type": .string("screenshotError"), "id": id, "message": .string("failed"),
            ])
        case .malformed:
            try h.sockets[0].receive(["type": .string("screenshot"), "id": id, "dataUri": .string("invalid")])
        case .disconnect: h.engine.close()
        }
    }
    var error: StreamError {
        switch self {
        case .timeout: .screenshotTimeout
        case .server, .malformed: .screenshotFailed
        case .disconnect: .disconnected
        }
    }
}

@Test("Screenshot failures settle callers", arguments: ScreenshotFailure.allCases) @MainActor
func sessionScreenshotFailure(failure: ScreenshotFailure) async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.negotiate()
    let pending = Task { try await h.engine.screenshot(timeout: 2) }
    await settle { h.sockets[0].frames("screenshot").count == 1 }
    try failure.fire(h)
    await #expect(throws: failure.error) { try await pending.value }
}

@Test("Screenshot cancellation cancels its pending request") @MainActor
func sessionScreenshotCancellation() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.negotiate()
    let pending = Task { try await h.engine.screenshot() }
    await settle { h.sockets[0].frames("screenshot").count == 1 }
    pending.cancel()
    await #expect(throws: CancellationError.self) { try await pending.value }
}

@Test("Huge screenshot timeouts clamp to one day", arguments: [Double.greatestFiniteMagnitude, .infinity])
@MainActor func sessionHugeScreenshotTimeout(timeout: Double) async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.connected()
    let pending = Task { try await h.engine.screenshot(timeout: timeout) }
    await settle { h.sockets[0].frames("screenshot").count == 1 }
    let day = 24 * 60 * 60 * 1000
    h.clock.advance(to: day - 1)
    #expect(h.engine.status == .connected)
    h.clock.advance(to: day)
    await #expect(throws: StreamError.screenshotTimeout) { try await pending.value }
}

@Test("Screenshot default timeout comes from the signalling contract") @MainActor
func sessionDefaultScreenshotTimeout() async throws {
    let h = try SessionHarness()
    defer { h.engine.close() }
    try await h.connected()
    let pending = Task { try await h.engine.screenshot() }
    await settle { h.sockets[0].frames("screenshot").count == 1 }
    h.clock.advance(to: SignallingTiming.screenshotTimeoutMs)
    await #expect(throws: StreamError.screenshotTimeout) { try await pending.value }
}
