// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MobilerunStream

/// Credential-free launch configuration; each session captures its own immutable backend target.
struct SampleBackend: Decodable, Sendable {
    let helperBaseUrl: URL
    let deviceId: String
    private let session: URLSession

    init(helperBaseUrl: URL, deviceId: String, session: URLSession? = nil) throws {
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(helperBaseUrl.host ?? "")
        let secure = helperBaseUrl.scheme == "https" && helperBaseUrl.host?.isEmpty == false
        let local = helperBaseUrl.scheme == "http" && loopback
        let validDevice = !deviceId.isEmpty && deviceId.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
        let credentialFree = helperBaseUrl.user == nil && helperBaseUrl.password == nil
        let plainAddress = helperBaseUrl.query == nil && helperBaseUrl.fragment == nil
        let validEndpoint = (secure || local) && credentialFree && plainAddress
        guard validEndpoint, validDevice else {
            throw BackendError.requestFailed
        }
        self.helperBaseUrl = helperBaseUrl
        self.deviceId = deviceId
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: configuration)
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(helperBaseUrl: fields.decode(URL.self, forKey: .helperBaseUrl),
                      deviceId: fields.decode(String.self, forKey: .deviceId))
    }
    private enum CodingKeys: String, CodingKey { case helperBaseUrl, deviceId }
    private struct Device: Decodable {
        let id: String?
        let state: String?
        let streamUrl: URL?
    }
    private struct Mint: Decodable { let key: String }

    func credentials() async throws -> StreamCredentials? {
        let data = try await request(mint: false)
        guard let device = try? JSONDecoder().decode(Device.self, from: data) else {
            throw BackendError.requestFailed
        }
        guard let url = device.streamUrl else { return nil }
        return StreamCredentials(url: url, tokenProvider: { try await mintStreamKey() })
    }

    func mintStreamKey() async throws -> String {
        let data = try await request(mint: true)
        guard let mint = try? JSONDecoder().decode(Mint.self, from: data) else {
            throw BackendError.requestFailed
        }
        return mint.key
    }

    private func request(mint: Bool) async throws -> Data {
        var url = helperBaseUrl.appendingPathComponent("api/v1/devices").appendingPathComponent(deviceId)
        if mint { url.appendPathComponent("stream-key") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = mint ? "POST" : "GET"
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            let expectedStatus = mint ? 201 : 200
            guard (response as? HTTPURLResponse)?.statusCode == expectedStatus else {
                throw BackendError.requestFailed
            }
            return data
        } catch { throw BackendError.requestFailed }
    }
}

private enum BackendError: LocalizedError {
    case requestFailed
    var errorDescription: String? { "Sample backend request failed." }
}

enum SampleLaunchConfiguration: Decodable {
    case helper(SampleBackend)
    case legacy(SampleCredentials)

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        if fields.contains(.helperBaseUrl) {
            self = .helper(try SampleBackend(from: decoder))
        } else {
            self = .legacy(try SampleCredentials(from: decoder))
        }
    }
    private enum CodingKeys: String, CodingKey { case helperBaseUrl }
}
