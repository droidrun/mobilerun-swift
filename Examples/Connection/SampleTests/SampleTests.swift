// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import XCTest
import SwiftUI
@testable import Connection
@testable import MobilerunStream

final class SampleCredentialsTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testConsumesTrimmedCredentialsOnlyOnce() throws {
        let file = folder.appendingPathComponent("credentials.json")
        try Data(#"{"streamUrl":"  wss://example.com/stream  ","streamToken":"  sample-secret  "}"#.utf8).write(to: file)
        let credentials = try XCTUnwrap(SampleCredentials.consume(file))
        XCTAssertEqual(credentials.streamUrl.absoluteString, "wss://example.com/stream")
        XCTAssertEqual(credentials.streamToken, "sample-secret")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(try SampleCredentials.consume(file))
    }
    func testRedactsCredentials() throws {
        let credentials = try SampleCredentials(url: "wss://example.com", token: "sample-secret")
        XCTAssertEqual(String(describing: credentials), "SampleCredentials(<redacted>)")
        XCTAssertEqual(String(reflecting: credentials), "SampleCredentials(<redacted>)")
    }
    private func assertRejected(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let path = folder.appendingPathComponent("credentials.json")
        try Data(json.utf8).write(to: path)
        XCTAssertThrowsError(try SampleCredentials.consume(path), file: file, line: line) { error in
            XCTAssertEqual(error as? SampleError, .invalidCredentials, file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), file: file, line: line)
    }
    func testRejectsMalformedCredentialsAndDeletesFile() throws {
        try assertRejected("invalid")
        try assertRejected("[]")
        try assertRejected("null")
        try assertRejected(#"{"streamUrl":"wss://example.com"}"#)
        try assertRejected(#"{"streamUrl":42,"streamToken":"sample-secret"}"#)
        try assertRejected(#"{"streamUrl":"wss://example.com","streamToken":42}"#)
        try assertRejected(#"{"streamUrl":"wss://example.com","streamToken":null}"#)
        try assertRejected(#"{"streamUrl":"wss://example.com","streamToken":" \n"}"#)
        try assertRejected(#"{"streamUrl":" ","streamToken":"sample-secret"}"#)
        try assertRejected(#"{"streamUrl":"https://example.com","streamToken":"sample-secret"}"#)
        try assertRejected(#"{"streamUrl":"wss:///stream","streamToken":"sample-secret"}"#)
        try assertRejected(#"{"streamUrl":"wss://","streamToken":"sample-secret"}"#)
    }
}

@MainActor final class SampleAppearanceTests: XCTestCase {
    func testAppearanceTokensAndLabels() {
        XCTAssertEqual(SampleAppearance.dark.theme(solid: false), .dark)
        XCTAssertEqual(SampleAppearance.light.theme(solid: true).surfaceStyle, .solid)
        XCTAssertEqual(SampleAppearance.dark.theme(solid: true).surfaceStyle, .solid)
        XCTAssertEqual(SampleAppearance.brand.theme(solid: true).surfaceStyle, .solid)
        XCTAssertEqual(SampleAppearance.light.theme(solid: false).surfaceStyle, .glass)
        XCTAssertEqual(SampleAppearance.dark.theme(solid: false).surfaceStyle, .glass)
        XCTAssertEqual(SampleAppearance.brand.theme(solid: false).surfaceStyle, .glass)
        XCTAssertEqual(SampleAppearance.brand.theme(solid: true).primary, .indigo)
        XCTAssertEqual(SampleAppearance.brand.theme(solid: true).radius, 20)
        XCTAssertEqual(SampleAppearance.brand.labels.back, "Go back")
        XCTAssertEqual(SampleAppearance.brand.labels.home, "Start")
        XCTAssertEqual(SampleAppearance.brand.labels.recent, "Apps")
        XCTAssertEqual(SampleAppearance.brand.labels.retry, "Try again")
        XCTAssertEqual(SampleAppearance.brand.approvalLabels.approve, "Allow")
        XCTAssertEqual(SampleAppearance.brand.approvalLabels.deny, "Decline")
    }

    func testCompositeHandleControlsMountedViewAndRespectsUnavailable() throws {
        let session = DeviceStreamSession(credentials: { nil })
        session.presentForTesting(.unavailable)
        let handle = DeviceStreamHandle()
        let host = UIHostingController(rootView: DeviceStream(session: session, handle: handle))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { handle.hideKeyboard(); window.isHidden = true; session.close() }
        expectation(for: NSPredicate { _, _ in handle.view?.window != nil }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        let view = try XCTUnwrap(handle.view)
        XCTAssertFalse(view.hasControl)
        handle.showKeyboard()
        XCTAssertFalse(view.textClient.isFirstResponder)
        session.presentForTesting(.connected)
        expectation(for: NSPredicate { _, _ in view.hasControl }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        handle.showKeyboard()
        XCTAssertTrue(view.textClient.isFirstResponder)
        handle.hideKeyboard()
        XCTAssertFalse(view.textClient.isFirstResponder)
    }
}

final class SampleHTTPProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var status = 200
    private static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let status = Self.status
        Self.lock.unlock()
        let mint = request.httpMethod == "POST"
        let body = mint
            ? #"{"key":" key-a &+%=","keyId":"id-a","expiresAt":"2026-11-20T12:02:00Z"}"#
            : #"{"id":"device-a","state":"ready","streamUrl":"wss://stream.test/a"}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: ["Cache-Control": "no-store"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset(status: Int = 200) {
        lock.lock()
        defer { lock.unlock() }
        requests = []
        self.status = status
    }
}

final class SampleBackendTests: XCTestCase {
    func testHelperLaunchConfigIsConsumedAndDeleted() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(#"{"helperBaseUrl":"http://localhost:3001","deviceId":"device-a"}"#.utf8).write(to: file)
        let launch = try XCTUnwrap(SampleCredentials.consume(file, as: SampleLaunchConfiguration.self))
        guard case .helper(let backend) = launch else { return XCTFail("Expected helper configuration") }
        XCTAssertEqual(backend.deviceId, "device-a")
        XCTAssertEqual(backend.helperBaseUrl.absoluteString, "http://localhost:3001")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(try SampleCredentials.consume(file, as: SampleLaunchConfiguration.self))
    }

    func testMalformedHelperLaunchConfigIsDeleted() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(#"{"helperBaseUrl":"http://public.test:3001","deviceId":"device-a"}"#.utf8).write(to: file)
        XCTAssertThrowsError(try SampleCredentials.consume(file, as: SampleLaunchConfiguration.self))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testBackendBindsDiscoveryAndEveryMintToOneDeviceWithoutStoringKeys() async throws {
        SampleHTTPProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SampleHTTPProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let backend = try SampleBackend(helperBaseUrl: URL(string: "http://localhost:3001")!,
                                        deviceId: "device-a", session: session)
        let discovered = try await backend.credentials()
        let target = try XCTUnwrap(discovered)
        XCTAssertNil(target.token)
        XCTAssertEqual(target.url.absoluteString, "wss://stream.test/a")
        let provider = try XCTUnwrap(target.tokenProvider)
        SampleHTTPProtocol.status = 201
        let first = try await provider()
        let second = try await provider()
        XCTAssertEqual(first, " key-a &+%=")
        XCTAssertEqual(second, " key-a &+%=")
        XCTAssertNil(target.token)
        XCTAssertEqual(SampleHTTPProtocol.requests.map(\.httpMethod), ["GET", "POST", "POST"])
        XCTAssertEqual(SampleHTTPProtocol.requests.map { $0.url!.path }, [
            "/api/v1/devices/device-a", "/api/v1/devices/device-a/stream-key",
            "/api/v1/devices/device-a/stream-key"
        ])
        XCTAssertTrue(SampleHTTPProtocol.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == nil &&
                $0.value(forHTTPHeaderField: "Cache-Control") == "no-store"
        })
        SampleHTTPProtocol.status = 403
        do {
            _ = try await provider()
            XCTFail("Expected refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Sample backend request failed.")
        }
        XCTAssertEqual(SampleHTTPProtocol.requests.count, 4)
    }
}
