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
