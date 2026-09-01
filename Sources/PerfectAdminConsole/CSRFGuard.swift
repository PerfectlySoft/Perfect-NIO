//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// CSRFGuard — validates CSRF protection on mutating (POST, DELETE) routes.
//
// Two independent checks run in order:
//   1. X-Admin-CSRF: 1 custom header must be present.
//      Custom headers cannot be sent cross-origin without a preflight, and the
//      admin server does not send Access-Control-Allow-Headers, so any preflight
//      will be rejected by the browser's CORS policy before the request is sent.
//   2. If the browser includes an Origin header, it must equal
//      http://127.0.0.1:<port>. Non-browser tools (curl, HTTPie) typically
//      omit Origin, so they are not blocked by check 2 alone.
//
// Call order in a mutating route handler:
//   try tokenStore.requireAuth(from: req.headers)   // 401 on bad/missing token
//   try requireCSRF(headers: req.headers, port: port) // 403 on CSRF violation

import PerfectNIO

/// Validates CSRF headers for a mutating admin route.
/// Throws `ErrorOutput(.forbidden)` on any violation.
func requireCSRF(headers: HTTPHeaders, port: Int) throws {
    let csrfHeader = headers.first(name: "X-Admin-CSRF") ?? ""
    guard csrfHeader == "1" else {
        throw ErrorOutput(status: .forbidden, description: "Missing X-Admin-CSRF: 1 header")
    }
    if let origin = headers.first(name: "Origin") {
        guard origin == "http://127.0.0.1:\(port)" else {
            throw ErrorOutput(status: .forbidden, description: "Cross-origin mutation rejected")
        }
    }
}
