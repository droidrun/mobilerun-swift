// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

func fixture<T: Decodable>(_ path: String, as type: T.Type = T.self) throws -> T {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("conformance/fixtures")
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: Data(contentsOf: root.appendingPathComponent(path)))
}

struct ScenarioFile: Decodable {
    let events: [String]
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
    let wsOpenTimeoutMs: Int
    let rtcConfigTimeoutMs: Int
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
