// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import MobilerunStreamCore

private struct InputVector: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let events: [Event]?
    let operation: String?
    let text: String?
    let compositionText: String?
    let videoWidth: Int?
    let videoHeight: Int?
    let viewWidth: Double?
    let viewHeight: Double?
    let rotation: Int?
    let x: Double?
    let y: Double?
    let h: Double?
    let v: Double?
    let buttons: Int?
    let expect: Expectation?
    var testDescription: String { name }

    struct Event: Decodable, Sendable {
        let type: String
        let code: String?
        let key: String?
        let shift: Bool?
        let alt: Bool?
        let ctrl: Bool?
        let meta: Bool?
        let capsLock: Bool?
        let clipboard: String?
        let id: Int?
        let x: Double?
        let y: Double?
        let mouse: Bool?
        let button: Int?
        let buttons: Int?
        var modifiers: InputModifiers {
            var flags: InputModifiers = []
            if shift == true { flags.insert(.shift) }
            if alt == true { flags.insert(.alternate) }
            if ctrl == true { flags.insert(.control) }
            if meta == true { flags.insert(.command) }
            if capsLock == true { flags.insert(.capsLock) }
            return flags
        }
    }
    enum Expectation: Decodable, Sendable {
        case packets([Packet])
        case geometry(Geometry)
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let packets = try? container.decode([Packet].self) { self = .packets(packets) }
            else { self = .geometry(try container.decode(Geometry.self)) }
        }
    }
    struct Packet: Decodable, Sendable, Equatable {
        let channel: String
        let hex: String
    }
    struct Geometry: Decodable, Sendable {
        let width: Int
        let height: Int
        let x: Double
        let y: Double
    }
}

private func inputVectors(_ file: String) throws -> [InputVector] {
    struct File: Decodable { let cases: [InputVector] }
    return try fixture("input/\(file).json", as: File.self).cases
}

private func packets(_ data: [Data], channel: String = "control") -> [InputVector.Packet] {
    data.map { InputVector.Packet(channel: channel, hex: hex($0)) }
}

struct InputConformanceTests {
    @Test(arguments: try inputVectors("keys"))
    fileprivate func keys(_ vector: InputVector) throws {
        var state = KeyInputState()
        var output: [Data] = []
        for event in try #require(vector.events) {
            output += state.route(code: try #require(event.code), text: try #require(event.key),
                down: event.type == "keydown", modifiers: event.modifiers, clipboard: { event.clipboard })
        }
        guard case .packets(let expected) = vector.expect else { Issue.record("missing packet oracle"); return }
        #expect(packets(output) == expected)
    }

    @Test(arguments: try inputVectors("ime"))
    fileprivate func ime(_ vector: InputVector) throws {
        let output: [Data]
        switch try #require(vector.operation) {
        case "commit", "composition_end": output = KeyInput.committedText(try #require(vector.text))
        case "composition_update": output = [] // Marked text remains in the native text client's buffer.
        case "delete": output = (try #require(vector.compositionText)).isEmpty ? KeyInput.press(67) : []
        default: Issue.record("unknown IME operation"); return
        }
        guard case .packets(let expected) = vector.expect else { Issue.record("missing packet oracle"); return }
        #expect(packets(output) == expected)
    }

    @Test(arguments: try inputVectors("geometry"))
    fileprivate func geometry(_ vector: InputVector) throws {
        let geometry = InputGeometry(bounds: CGRect(x: 0, y: 0,
            width: try #require(vector.viewWidth), height: try #require(vector.viewHeight)),
            video: VideoSize(width: try #require(vector.videoWidth), height: try #require(vector.videoHeight),
                             rotation: try #require(vector.rotation)))
        let point = geometry?.map(CGPoint(x: try #require(vector.x), y: try #require(vector.y)))
        guard case .geometry(let expected) = vector.expect else { #expect(point == nil); return }
        let mapped = try #require(point)
        #expect(geometry?.videoWidth == expected.width)
        #expect(geometry?.videoHeight == expected.height)
        #expect(abs(mapped.x - expected.x) < 0.000001)
        #expect(abs(mapped.y - expected.y) < 0.000001)
    }

    @Test(arguments: try inputVectors("scroll"))
    fileprivate func scroll(_ vector: InputVector) throws {
        let width = try #require(vector.videoWidth)
        let height = try #require(vector.videoHeight)
        let geometry = InputGeometry(bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                     video: VideoSize(width: width, height: height))
        let packet = try geometry.flatMap { geometry in
            ScrollInput.route(at: CGPoint(x: try #require(vector.x), y: try #require(vector.y)),
                geometry: geometry, h: try #require(vector.h), v: try #require(vector.v), buttons: try #require(vector.buttons))
        }
        guard case .packets(let expected) = vector.expect else { Issue.record("missing packet oracle"); return }
        #expect(packets(packet.map { [$0] } ?? []) == expected)
    }

    @Test(arguments: try inputVectors("pointers"))
    fileprivate func pointers(_ vector: InputVector) throws {
        enum Identity: Hashable { case mouse, touch(Int) }
        var state = PointerInput<Identity>()
        let width = try #require(vector.videoWidth)
        let height = try #require(vector.videoHeight)
        guard let geometry = InputGeometry(bounds: CGRect(x: 0, y: 0, width: width, height: height),
            video: VideoSize(width: width, height: height)) else {
            guard case .packets(let expected) = vector.expect else { Issue.record("missing oracle"); return }
            #expect(expected.isEmpty)
            return
        }
        var output: [InputVector.Packet] = []
        for event in try #require(vector.events) {
            let mouse = try #require(event.mouse)
            let id: Identity = mouse ? .mouse : .touch(try #require(event.id))
            let point = CGPoint(x: try #require(event.x), y: try #require(event.y))
            let button = try #require(event.button)
            switch event.type {
            case "down":
                if let packet = state.down(id, at: point, geometry: geometry, mouse: mouse, button: button) {
                    output += packets([packet])
                }
            case "move":
                if mouse && !state.isActive(id) {
                    output += packets(state.hover(at: point, geometry: geometry,
                        buttons: try #require(event.buttons)).map { [$0] } ?? [], channel: "hover")
                } else {
                    state.move(id, to: point)
                    output += packets(state.flushMoves()) // Abstract vectors have no display-frame coalescing.
                }
            case "up", "cancel":
                if let packet = state.up(id, cancelled: event.type == "cancel", button: button) {
                    output += packets([packet])
                }
            default: Issue.record("unknown pointer event")
            }
        }
        guard case .packets(let expected) = vector.expect else { Issue.record("missing packet oracle"); return }
        #expect(output == expected)
    }

    @Test(arguments: [("keys", 114), ("ime", 21), ("pointers", 18), ("geometry", 25), ("scroll", 21)])
    func allCasesLoaded(file: String, count: Int) throws {
        #expect(try inputVectors(file).count == count)
    }
}
