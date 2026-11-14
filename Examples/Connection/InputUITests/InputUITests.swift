// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import XCTest

@MainActor final class InputUITests: XCTestCase {
    func testNativeTapAndHardwareKey() throws {
        let app = XCUIApplication(bundleIdentifier: "io.mobilerun.Connection")
        app.activate()
        XCTAssertTrue(app.staticTexts["connected"].waitForExistence(timeout: 45))
        let surface = app.otherElements["device-stream-surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 20))
        let size = try XCTUnwrap(surface.value as? String).split(separator: "x").compactMap { Double($0) }
        guard size.count == 4 else { XCTFail("video size or scenario target missing"); return }
        let frame = surface.frame
        let scale = min(frame.width / size[0], frame.height / size[1])
        let videoWidth = size[0] * scale
        let videoHeight = size[1] * scale
        // The external scenario supplies a fixed video-space target; no target selection occurs here.
        let x = (frame.width - videoWidth) / 2 + videoWidth * size[2]
        let y = (frame.height - videoHeight) / 2 + videoHeight * size[3]
        surface.coordinate(withNormalizedOffset: CGVector(dx: x / frame.width, dy: y / frame.height)).tap()
        let delivered = app.staticTexts["last-native-input"]
        expectation(for: NSPredicate(format: "label == %@", "touch"), evaluatedWith: delivered)
        waitForExpectations(timeout: 5)
        app.typeKey("x", modifierFlags: [])
        expectation(for: NSPredicate(format: "label == %@", "press"), evaluatedWith: delivered)
        waitForExpectations(timeout: 5)
    }
}
