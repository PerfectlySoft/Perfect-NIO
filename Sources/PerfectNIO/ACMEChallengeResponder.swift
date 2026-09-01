//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// ACME HTTP-01 challenge helper. Serves Let's Encrypt validation tokens on
// the HTTP (port 80) server while a renewal is in progress, and returns 404
// at all other times.
//
// Security model: the "window" is open only while an active token is registered
// (~30-60 seconds during renewal). With no tokens registered the route is
// indistinguishable from a 404. No special enable/disable switch is needed.
//
// Mount the route on the HTTP redirect server alongside the redirect handler:
//
//   let acme = ACMEChallengeResponder()
//
//   // During renewal (called by your ACME client or certbot hook):
//   await acme.addChallenge(token: t, keyAuthorization: k)
//   // ... Let's Encrypt validates ...
//   await acme.removeChallenge(token: t)
//
//   // Route registration (on the port-80 redirect server):
//   routes.add(method: .get, uri: "/.well-known/acme-challenge/:token") { req in
//       guard let token = req.params["token"],
//             let response = await acme.response(for: token)
//       else { throw TerminationType.criteriaFailed(.notFound) }
//       return TextOutput(response, contentType: "text/plain")
//   }
//
// The actual ACME protocol (CSR, order creation, cert download) is handled by
// an external tool (certbot, acme.sh) or a future PerfectACME package.

/// Thread-safe store for active ACME HTTP-01 challenge tokens.
///
/// One instance is typically shared between the ACME renewal logic and the
/// HTTP server that serves port 80.
public actor ACMEChallengeResponder {
	private var pending: [String: String] = [:] // token → keyAuthorization

	public init() {}

	/// Register a challenge token returned by the ACME server.
	///
	/// Call this immediately before Let's Encrypt attempts validation.
	public func addChallenge(token: String, keyAuthorization: String) {
		pending[token] = keyAuthorization
	}

	/// Remove a token after validation succeeds or fails.
	///
	/// After this call, requests for that token return 404.
	public func removeChallenge(token: String) {
		pending.removeValue(forKey: token)
	}

	/// Returns the key-authorization string for a token, or nil if no active
	/// challenge exists for that token (the server should respond with 404).
	public func response(for token: String) -> String? {
		pending[token]
	}

	/// True if any challenge tokens are currently registered.
	public var hasPendingChallenges: Bool { !pending.isEmpty }

	/// The count of currently registered challenge tokens.
	public var pendingCount: Int { pending.count }
}
