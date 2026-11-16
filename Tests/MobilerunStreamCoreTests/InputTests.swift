// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoreGraphics
import Testing
import MobilerunProtocol
@testable import MobilerunStreamCore

struct InputTests {
    @Test(arguments: [
        (100, 200, 0, CGRect(x: 50, y: 0, width: 100, height: 200)),
        (200, 100, 0, CGRect(x: 0, y: 50, width: 200, height: 100)),
        (100, 200, 90, CGRect(x: 0, y: 50, width: 200, height: 100)),
        (100, 200, 270, CGRect(x: 0, y: 50, width: 200, height: 100)),
        (100, 200, 180, CGRect(x: 50, y: 0, width: 100, height: 200)),
    ])
    func aspectFitAndRotation(width: Int, height: Int, rotation: Int, expected: CGRect) throws {
        let geometry = try #require(InputGeometry(
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
            video: VideoSize(width: width, height: height, rotation: rotation)))
        #expect(geometry.rect == expected)
        #expect(geometry.map(CGPoint(x: expected.minX, y: expected.minY)) == CGPoint(x: 0, y: 0))
        #expect(geometry.map(CGPoint(x: expected.maxX, y: expected.maxY)) == CGPoint(
            x: Double(geometry.videoWidth), y: Double(geometry.videoHeight)))
        #expect(geometry.map(CGPoint(x: expected.midX, y: expected.midY)) == CGPoint(
            x: Double(geometry.videoWidth) / 2, y: Double(geometry.videoHeight) / 2))
        #expect(geometry.map(CGPoint(x: expected.minX - 0.01, y: expected.midY)) == nil)
    }

    @Test func invalidGeometryAndNonzeroOrigin() throws {
        #expect(InputGeometry(bounds: .zero, video: VideoSize(width: 100, height: 100)) == nil)
        #expect(InputGeometry(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), video: nil) == nil)
        #expect(InputGeometry(bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                              video: VideoSize(width: 0, height: 100)) == nil)
        let geometry = try #require(InputGeometry(bounds: CGRect(x: 30, y: 40, width: 100, height: 100),
                                                  video: VideoSize(width: 200, height: 200)))
        #expect(geometry.map(CGPoint(x: 80, y: 90)) == CGPoint(x: 100, y: 100))
        #expect(geometry.map(CGPoint(x: Double.nan, y: 50)) == nil)
    }

    private func geometry() throws -> InputGeometry {
        try #require(InputGeometry(bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
                                   video: VideoSize(width: 100, height: 200)))
    }

    private func touch(_ action: Int, _ slot: Int64, _ x: Double, _ y: Double) -> Data {
        ControlMessages.touch(action: action, pointerID: slot, videoWidth: 100, videoHeight: 200,
                              x: x, y: y, pressure: 1, actionButton: 1, buttons: 1)
    }

    @Test func reactOutsideDownIsIgnoredAndUpUsesLastInVideoPosition() throws {
        var input = PointerInput<Int>()
        let geometry = try geometry()
        #expect(input.down(1, at: .zero, geometry: geometry) == nil)
        #expect(input.up(1) == nil)
        #expect(input.down(2, at: CGPoint(x: 70, y: 20), geometry: geometry) == touch(0, 0, 20, 20))
        input.move(2, to: CGPoint(x: 80, y: 30))
        input.move(2, to: .zero)
        #expect(input.up(2) == touch(1, 0, 30, 30))
        #expect(input.flushMoves().isEmpty)
    }

    @Test func stableSlotsAreReusedAndMouseIsIndependent() throws {
        var input = PointerInput<Int>()
        let geometry = try geometry()
        for id in 0..<10 {
            #expect(input.down(id, at: CGPoint(x: 60, y: 20), geometry: geometry)
                    == touch(0, Int64(id), 10, 20))
        }
        #expect(input.down(10, at: CGPoint(x: 60, y: 20), geometry: geometry) == nil)
        #expect(input.down(100, at: CGPoint(x: 60, y: 20), geometry: geometry, mouse: true)
                == touch(0, -1, 10, 20))
        #expect(input.down(101, at: CGPoint(x: 60, y: 20), geometry: geometry, mouse: true) == nil)
        #expect(input.up(4, cancelled: true) == touch(3, 4, 10, 20))
        #expect(input.down(40, at: CGPoint(x: 60, y: 20), geometry: geometry) == touch(0, 4, 10, 20))
        #expect(input.cancel() == [touch(3, -1, 10, 20)] + (0..<10).map { touch(3, Int64($0), 10, 20) })
        #expect(input.up(0) == nil)
    }

    @Test func movesCoalescePerFingerAndCancelDropsAllPendingInput() throws {
        var input = PointerInput<Int>()
        let geometry = try geometry()
        _ = input.down(9, at: CGPoint(x: 60, y: 20), geometry: geometry)
        _ = input.down(8, at: CGPoint(x: 60, y: 20), geometry: geometry)
        for value in 1...20 { input.move(9, to: CGPoint(x: 60 + value, y: 20)) }
        input.move(8, to: CGPoint(x: 100, y: 30))
        #expect(input.flushMoves() == [touch(2, 0, 30, 20), touch(2, 1, 50, 30)])
        #expect(input.flushMoves().isEmpty)
        #expect(input.cancel() == [touch(3, 0, 30, 20), touch(3, 1, 50, 30)])
        #expect(input.up(9) == nil)
    }

    @Test func hidMapCoversExactlyTheFixtureCodes() {
        #expect(Set(HIDCode.values.values) == Set(KeyboardCode.values.keys))
        #expect(HIDCode.values[4] == "KeyA")
        #expect(HIDCode.values[40] == "Enter")
        #expect(HIDCode.values[231] == "MetaRight")
    }

    @Test func committedIMETextAndReturn() {
        #expect(KeyInput.committedText("你好🙂\nnext\r\n") ==
                [ControlMessages.text("你好🙂")] + KeyInput.press(66)
                + [ControlMessages.text("next")] + KeyInput.press(66))
        #expect(KeyInput.committedText("").isEmpty)
        #expect(KeyInput.committedText("👩‍💻") == [ControlMessages.text("👩‍💻")])
        #expect(KeyInput.committedText("a\u{1}\tb") ==
                [ControlMessages.text("a")] + KeyInput.press(61) + [ControlMessages.text("b")])
    }
}
