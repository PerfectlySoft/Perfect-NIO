//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//

import NIOSSL

/// Thread-safe, live-updatable map from hostname to TLS context.
///
/// A single `TLSContextManager` can serve dozens of domains simultaneously.
/// Certs can be added, replaced, or removed at runtime — the next connection
/// for that hostname picks up the change immediately without a server restart.
///
/// ```swift
/// let certManager = try TLSContextManager(default: defaultConfig)
/// try await certManager.setCertificate(for: "tenant.example.com", config: tenantConfig)
///
/// let server = Server(routes: appRoutes, port: 443, tlsManager: certManager)
/// try await server.run()
/// ```
public actor TLSContextManager {

	private var contexts: [String: NIOSSLContext] = [:]
	private var defaultContext: NIOSSLContext?

	/// Creates a manager with an optional fallback cert for unmatched hostnames.
	///
	/// When `default` is nil the server closes connections whose SNI hostname
	/// doesn't match any registered cert rather than presenting the wrong cert.
	public init(default config: TLSConfiguration? = nil) throws {
		self.defaultContext = try config.map { try NIOSSLContext(configuration: $0) }
	}

	/// Add or replace the cert for a domain. Safe to call while the server is running.
	public func setCertificate(for hostname: String, config: TLSConfiguration) throws {
		contexts[hostname] = try NIOSSLContext(configuration: config)
	}

	/// Remove a domain's cert. Subsequent connections for that hostname fall back
	/// to the default context (or are refused if no default is set).
	public func removeCertificate(for hostname: String) {
		contexts.removeValue(forKey: hostname)
	}

	/// Returns the best-matching context for the given SNI hostname.
	/// Returns nil when neither a domain match nor a default exists.
	func context(for hostname: String?) -> NIOSSLContext? {
		hostname.flatMap { contexts[$0] } ?? defaultContext
	}

	/// All hostnames that have an explicitly registered cert, sorted.
	public func registeredHostnames() -> [String] {
		Array(contexts.keys).sorted()
	}

	/// True when a fallback cert is registered for unmatched hostnames.
	public var hasDefaultContext: Bool { defaultContext != nil }
}
