// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunProtocol
import Testing

let fixturesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("conformance/fixtures")

func fixture<T: Decodable>(_ path: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: fixturesURL.appendingPathComponent(path)))
}

struct ControlCase: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let args: Args
    let hex: String
    var file = ""
    var testDescription: String { "\(file): \(name)" }

    enum CodingKeys: String, CodingKey { case name, args, hex }

    struct Args: Decodable, Sendable {
        let action: Int?
        let pointerId: Int64?
        let videoWidth: Int?
        let videoHeight: Int?
        let x: Double?
        let y: Double?
        let pressure: Double?
        let actionButton: Int?
        let buttons: Int?
        let hscrollTicks: Double?
        let vscrollTicks: Double?
        let keycode: Int?
        let `repeat`: Int?
        let metaState: Int?
        let text: String?
        let paste: Bool?
    }
}

func controlCases() throws -> [ControlCase] {
    struct File: Decodable { let cases: [ControlCase] }
    return try FileManager.default.contentsOfDirectory(atPath: fixturesURL.appendingPathComponent("control").path)
        .sorted().flatMap { file in
            try fixture("control/\(file)", as: File.self).cases.map {
                var item = $0
                item.file = file
                return item
            }
        }
}

struct SignallingCase: Sendable, CustomTestStringConvertible {
    let file: String
    let name: String
    let json: [String: JSONValue]
    var testDescription: String { "\(file): \(name)" }
}

func signallingCases() throws -> [SignallingCase] {
    struct File: Decodable {
        struct Example: Decodable { let name: String; let json: [String: JSONValue] }
        let examples: [Example]
    }
    return try FileManager.default.contentsOfDirectory(atPath: fixturesURL.appendingPathComponent("signalling").path)
        .filter { $0.hasPrefix("client-") || $0.hasPrefix("server-") }.sorted().flatMap { file in
            try fixture("signalling/\(file)", as: File.self).examples.map {
                SignallingCase(file: file, name: $0.name, json: $0.json)
            }
        }
}

extension JSONValue {
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var intValue: Int? { if case .number(let value) = self { Int(exactly: value) } else { nil } }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
}

func jsonObject(_ text: String) throws -> [String: JSONValue] {
    try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
}

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
