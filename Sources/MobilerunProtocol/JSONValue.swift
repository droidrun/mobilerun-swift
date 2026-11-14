// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A JSON value, used to preserve extensible RTC configuration fields without a WebRTC dependency.
public enum JSONValue: Sendable, Equatable, Codable {
    /// JSON object.
    case object([String: JSONValue])
    /// JSON array.
    case array([JSONValue])
    /// JSON string.
    case string(String)
    /// JSON number.
    case number(Double)
    /// JSON boolean.
    case bool(Bool)
    /// JSON null.
    case null

    /// Decodes a JSON value using the standard Codable representation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    /// Encodes the value as JSON.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
}

func jsonText(_ object: [String: JSONValue]) throws -> String {
    String(decoding: try JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self)
}
