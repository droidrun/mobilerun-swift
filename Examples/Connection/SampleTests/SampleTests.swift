// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import Connection

final class SampleCredentialsTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testConsumesValidFileOnlyOnceAndRedactsToken() throws {
        let file = folder.appendingPathComponent("credentials.json")
        try Data(#"{"streamUrl":"wss://example.com/stream","streamToken":"sample-secret"}"#.utf8).write(to: file)
        let credentials = try XCTUnwrap(SampleCredentials.consume(file))
        XCTAssertEqual(credentials.streamUrl.absoluteString, "wss://example.com/stream")
        XCTAssertEqual(credentials.streamToken, "sample-secret")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(try SampleCredentials.consume(file))
        XCTAssertEqual(String(describing: credentials), "SampleCredentials(<redacted>)")
        XCTAssertEqual(String(reflecting: credentials), "SampleCredentials(<redacted>)")
    }
    func testMalformedFileIsDeleted() throws {
        let file = folder.appendingPathComponent("credentials.json")
        try Data("invalid".utf8).write(to: file)
        XCTAssertThrowsError(try SampleCredentials.consume(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testMissingTokenIsRejectedAndDeleted() throws {
        let file = folder.appendingPathComponent("credentials.json")
        try Data(#"{"streamUrl":"wss://example.com"}"#.utf8).write(to: file)
        XCTAssertThrowsError(try SampleCredentials.consume(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testBlankTokenIsRejected() {
        XCTAssertThrowsError(try SampleCredentials(url: "wss://example.com", token: " \n"))
    }
    func testBlankURLIsRejected() {
        XCTAssertThrowsError(try SampleCredentials(url: " ", token: "sample-secret"))
    }
}

@MainActor final class SampleAppearanceTests: XCTestCase {
    func testDarkBrandTokensAndLabels() {
        XCTAssertEqual(SampleAppearance.dark.theme(solid: false), .dark)
        XCTAssertEqual(SampleAppearance.brand.theme(solid: true).primary, .indigo)
        XCTAssertEqual(SampleAppearance.brand.theme(solid: true).radius, 20)
        XCTAssertEqual(SampleAppearance.brand.theme(solid: true).surfaceStyle, .solid)
        XCTAssertEqual(SampleAppearance.brand.labels.back, "Go back")
        XCTAssertEqual(SampleAppearance.brand.labels.home, "Start")
        XCTAssertEqual(SampleAppearance.brand.approvalLabels.approve, "Allow")
        XCTAssertEqual(SampleAppearance.brand.approvalLabels.deny, "Decline")
    }
}
