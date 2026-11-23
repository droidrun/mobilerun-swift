// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import os

/// Developer-facing notices. Messages never contain endpoints or credentials.
enum StreamLog {
    private static let logger = Logger(subsystem: "ai.mobilerun.stream", category: "credentials")
    static func warn(_ message: String) { logger.warning("\(message, privacy: .public)") }
}
