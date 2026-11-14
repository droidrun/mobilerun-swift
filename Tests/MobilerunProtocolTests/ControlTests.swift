// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol
import Testing

@Test("Control packet bytes", arguments: try controlCases())
func controlPacket(_ item: ControlCase) throws {
    let a = item.args
    let bytes: Data
    switch item.file {
    case "touch.json":
        bytes = try ControlMessages.touch(
            action: #require(a.action), pointerId: #require(a.pointerId),
            videoWidth: #require(a.videoWidth), videoHeight: #require(a.videoHeight),
            x: #require(a.x), y: #require(a.y), pressure: #require(a.pressure),
            actionButton: #require(a.actionButton), buttons: #require(a.buttons))
    case "scroll.json":
        bytes = try ControlMessages.scroll(
            videoWidth: #require(a.videoWidth), videoHeight: #require(a.videoHeight),
            x: #require(a.x), y: #require(a.y), hscrollTicks: #require(a.hscrollTicks),
            vscrollTicks: #require(a.vscrollTicks), buttons: #require(a.buttons))
    case "hover.json":
        bytes = try ControlMessages.hover(videoWidth: #require(a.videoWidth), videoHeight: #require(a.videoHeight),
                                         x: #require(a.x), y: #require(a.y), buttons: #require(a.buttons))
    case "keycode.json":
        bytes = try ControlMessages.keycode(action: #require(a.action), keycode: #require(a.keycode),
                                           repeat: #require(a.repeat), metaState: #require(a.metaState))
    case "text.json": bytes = try ControlMessages.text(text: #require(a.text))
    case "set-clipboard.json": bytes = try ControlMessages.setClipboard(text: #require(a.text), paste: #require(a.paste))
    default: Issue.record("Unhandled control fixture \(item.file)"); return
    }
    #expect(hex(bytes) == item.hex)
}

@Test("Unpaired UTF-16 surrogates encode as U+FFFD", arguments: [[UInt16(0xd800)], [UInt16(0xdc00)], [UInt16(0xd800), 0x61, 0xdc00]])
func surrogateReplacement(_ units: [UInt16]) {
    let text = String(decoding: units, as: UTF16.self)
    let expected = units.count == 1 ? "efbfbd" : "efbfbd61efbfbd"
    #expect(hex(ControlMessages.text(text: text).dropFirst(5)) == expected)
    #expect(hex(ControlMessages.setClipboard(text: text).dropFirst(14)) == expected)
}

@Test("Narrow integers wrap, coordinates use DataView numeric conversion")
func numericEdges() {
    #expect(hex(ControlMessages.keycode(action: 256, keycode: Int(UInt32.max) + 1, repeat: -1, metaState: 0))
            == "000000000000ffffffff00000000")
    let packet = ControlMessages.hover(videoWidth: 65536, videoHeight: -1, x: .infinity, y: .nan)
    #expect(hex(packet) == "1500000000000000000000ffff00000000")
    let wrapped = ControlMessages.hover(videoWidth: 1, videoHeight: 1, x: 4_294_967_297, y: -4_294_967_297)
    #expect(hex(wrapped) == "1501000000ffffffff0100010000000000")
}

@Test("Every generated constant equals the pinned fixture")
func constants() throws {
    let expected = try fixture("constants.json", as: [String: [String: Int]].self)
    #expect(expected["control_msg_type"] == ControlMessageType.values)
    #expect(expected["amotion_event"] == MotionEvent.values)
    #expect(expected["android_keys"] == AndroidKey.values)
    #expect(expected["code_map"] == KeyboardCode.values)
}
