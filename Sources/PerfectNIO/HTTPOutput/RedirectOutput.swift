//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//

import NIOHTTP1

/// An HTTP redirect response.
///
/// Defaults to 308 (Permanent Redirect) which preserves the HTTP method across
/// the redirect. Pass `.movedPermanently` (301) only for legacy client compat.
public final class RedirectOutput: HTTPOutput, @unchecked Sendable {
	private let location: String
	private let redirectStatus: HTTPResponseStatus

	public init(to location: String, status: HTTPResponseStatus = .permanentRedirect) {
		self.location = location
		self.redirectStatus = status
		super.init()
	}

	public override func head(request: HTTPRequestInfo) -> HTTPHead? {
		HTTPHead(status: redirectStatus,
		         headers: HTTPHeaders([("location", location)]))
	}
	// nextChunk returns nil by default — no body for a redirect
}
