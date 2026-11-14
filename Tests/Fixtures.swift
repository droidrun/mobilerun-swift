// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import MobilerunProtocol
import Testing

let fixturesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("conformance/fixtures")

func fixture<T: Decodable>(_ path: String, as type: T.Type = T.self) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let data = try Data(contentsOf: fixturesURL.appendingPathComponent(path))
    return try decoder.decode(type, from: repairingJSONSurrogates(data))
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
    let directory = fixturesURL.appendingPathComponent("control").path
    return try FileManager.default.contentsOfDirectory(atPath: directory)
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

func signallingCases(prefix: String) throws -> [SignallingCase] {
    struct File: Decodable {
        struct Example: Decodable { let name: String; let json: [String: JSONValue] }
        let examples: [Example]
    }
    let directory = fixturesURL.appendingPathComponent("signalling").path
    return try FileManager.default.contentsOfDirectory(atPath: directory)
        .filter { $0.hasPrefix(prefix) }.sorted().flatMap { file in
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

struct ScenarioFile: Decodable {
    let scenarios: [Scenario]
}

struct Scenario: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let random: Double
    let steps: [Step]
    let expect: [Expectation]
    var testDescription: String { name }

    struct Step: Decodable, Sendable { let atMs: Int; let event: String }
    struct Expectation: Decodable, Sendable {
        let atMs: Int
        let afterSteps: Int
        let status: String
        let attempt: Int
        let healCalls: Int
        let remountCalls: Int
        let deferTargetChange: Bool?
        let pendingTimers: Int?
    }
}

struct Policy: Decodable {
    let maxAttempts: Int
    let connectTimeoutMs: Int
    let stabilityMs: Int
    let backoff: Backoff
    let delayCases: [Delay]
    struct Backoff: Decodable { let baseDelayMs: Int; let maxDelayMs: Int }
    struct Delay: Decodable, Sendable, CustomTestStringConvertible {
        let attempt: Int
        let random: Double
        let delayMs: Int
        var testDescription: String { "attempt \(attempt), random \(random)" }
    }
}
