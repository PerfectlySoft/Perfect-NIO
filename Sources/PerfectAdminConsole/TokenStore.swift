//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// AdminTokenStore — generates a cryptographically random bearer token, writes
// it to a caller-specified path (chmod 600), and validates incoming tokens
// with a constant-time comparison to prevent timing oracles.
//
// The token PERSISTS across restarts by default (reused from the existing
// token file if present and well-formed) rather than rotating on every
// launch — re-pasting a fresh token into the dashboard after every restart
// during normal development was pure friction with no real security
// benefit: the file is already chmod 600 (owner-only), so anyone able to
// read it already has the same local access they'd need to read a
// freshly-generated one on the next launch anyway. Pass `forceNewToken:
// true` to rotate explicitly (e.g. after a suspected leak).

import Foundation
import PerfectNIO

struct AdminTokenStore: Sendable {
    let token: String
    let filePath: String

    /// - Parameters:
    ///   - tokenFilePath: Path where the token is read from (if reusing) and written to.
    ///   - forceNewToken: When `true`, always generates a fresh token and
    ///     overwrites any existing one — the explicit rotation path. Default
    ///     `false`: reuse the existing file's token if it's present and
    ///     looks like a valid 64-hex-char token; only generate fresh when
    ///     the file is missing, empty, or malformed.
    init(tokenFilePath: String, forceNewToken: Bool = false) throws {
        filePath = tokenFilePath

        if !forceNewToken, let existing = Self.existingValidToken(atPath: tokenFilePath) {
            token = existing
        } else {
            // 32 random bytes → 64 lowercase hex chars
            var rng = SystemRandomNumberGenerator()
            let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
            token = bytes.map { String(format: "%02x", $0) }.joined()

            let url = URL(fileURLWithPath: tokenFilePath)
            try (token + "\n").write(to: url, atomically: true, encoding: .utf8)
        }

        // chmod 600: owner read+write only — other processes on the same machine
        // can still hit the localhost admin port, but they can't read the token file.
        // Applied unconditionally (even when reusing an existing token) in case the
        // file was somehow created with looser permissions by something else.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: tokenFilePath
        )
    }

    /// Reads and validates a pre-existing token file. Returns `nil` (rather
    /// than throwing) for anything that doesn't look like a genuine token —
    /// missing file, unreadable, wrong length, non-hex content — so the
    /// caller falls through to generating a fresh one instead of ever
    /// crashing on a stale/corrupt file.
    private static func existingValidToken(atPath path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let candidate = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count == 64, candidate.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return candidate
    }

    /// Extracts and validates the bearer token from an HTTP Authorization header.
    /// Throws `ErrorOutput(.unauthorized)` on any failure so the caller can just `try`.
    func requireAuth(from headers: HTTPHeaders) throws {
        let header = headers.first(name: "Authorization") ?? ""
        guard header.lowercased().hasPrefix("bearer ") else {
            throw ErrorOutput(status: .unauthorized, description: "Missing Authorization: Bearer header")
        }
        let candidate = String(header.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
        guard constantTimeEqual(candidate, token) else {
            throw ErrorOutput(status: .unauthorized, description: "Invalid token")
        }
    }

    // XOR-fold all byte pairs — same cost regardless of where the first mismatch is.
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        return zip(ab, bb).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
