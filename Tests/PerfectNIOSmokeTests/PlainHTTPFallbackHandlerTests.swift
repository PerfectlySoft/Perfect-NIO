//
//  PlainHTTPFallbackHandlerTests.swift
//  PerfectNIOSmokeTests
//
//  Pure unit tests for PlainHTTPFallbackHandler, the terminal handler in the pre-13.0
//  WebSocket-upgrade fallback pipeline (see Server.swift's configureUpgradeFallback).
//  No network I/O — EmbeddedChannel only.
//
//  Note: EmbeddedEventLoop has no background thread, so `.wait()` on a future tied to it
//  would block forever unless already fulfilled. Every assertion here instead captures the
//  result synchronously via `whenComplete`, which fires inline within EmbeddedChannel's own
//  synchronous operations (addHandler/writeInbound/close all resolve within the same call).
//

import XCTest
import NIO
import NIOCore
import NIOHTTP1
import NIOEmbedded
import NIOConcurrencyHelpers
@testable import PerfectNIO

final class PlainHTTPFallbackHandlerTests: XCTestCase {

	/// If the channel closes before any request ever arrives (a health-check probe, a TLS-handshake
	/// failure, a port scanner), `handlerRemoved` must fail the promise. Without it the promise would
	/// never resolve, hanging the accept loop's per-connection task forever.
	func testHandlerRemoved_beforeAnyData_failsThePromise() throws {
		let channel = EmbeddedChannel()
		defer { _ = try? channel.finish() }
		let promise = channel.eventLoop.makePromise(of: HTTPOrWebSocket.self)
		let result = NIOLockedValueBox<Result<HTTPOrWebSocket, Error>?>(nil)
		promise.futureResult.whenComplete { outcome in result.withLockedValue { $0 = outcome } }

		try channel.pipeline.syncOperations.addHandler(PlainHTTPFallbackHandler(idleTimeout: nil, promise: promise))

		// Simulate the connection being torn down before any request part ever arrived.
		// EmbeddedChannel's close0 succeeds the close future immediately but defers
		// removeHandlers (and thus handlerRemoved) onto the event loop's own task queue — so an
		// explicit run() is needed to actually flush it, distinct from waiting on close()'s future.
		try channel.close().wait()
		channel.embeddedEventLoop.run()

		switch result.withLockedValue({ $0 }) {
		case .failure(let error):
			XCTAssertEqual(error as? ChannelError, .inputClosed)
		case .success, .none:
			XCTFail("expected the promise to fail, got \(String(describing: result.withLockedValue({ $0 })))")
		}
	}

	/// `suppressResolution()` (called by the successful-WebSocket-upgrade path right before removing
	/// this handler) must prevent `handlerRemoved` from firing a spurious failure that would otherwise
	/// race the real success fulfilled separately by the WebSocket upgrader.
	func testSuppressResolution_preventsHandlerRemovedFromFailingThePromise() throws {
		let channel = EmbeddedChannel()
		defer { _ = try? channel.finish() }
		let promise = channel.eventLoop.makePromise(of: HTTPOrWebSocket.self)
		let result = NIOLockedValueBox<Result<HTTPOrWebSocket, Error>?>(nil)
		promise.futureResult.whenComplete { outcome in result.withLockedValue { $0 = outcome } }

		let handler = PlainHTTPFallbackHandler(idleTimeout: nil, promise: promise)
		try channel.pipeline.syncOperations.addHandler(handler)

		handler.suppressResolution()
		try channel.pipeline.syncOperations.removeHandler(handler).wait()

		// If handlerRemoved had NOT been suppressed, it would already have failed the promise here.
		XCTAssertNil(result.withLockedValue { $0 }, "removal alone must not resolve the promise once suppressed")

		// Mirrors what the real WebSocket-upgrade path does next; a prior spurious failure above
		// would make this either trap on double-fulfillment or simply never be observed as .success.
		let httpChannel = try HTTPConnectionChannel(wrappingChannelSynchronously: channel)
		promise.succeed(.http(httpChannel))

		guard case .success(let value) = result.withLockedValue({ $0 }), case .http = value else {
			XCTFail("expected .success(.http), got \(String(describing: result.withLockedValue({ $0 })))")
			return
		}
	}

	/// The first inbound request part must resolve the promise as `.http`, matching
	/// `HTTPServerUpgradeHandler`'s not-upgrading forwarding contract.
	func testChannelRead_firstPart_resolvesAsHTTP() throws {
		let channel = EmbeddedChannel()
		defer { _ = try? channel.finish() }
		let promise = channel.eventLoop.makePromise(of: HTTPOrWebSocket.self)
		let result = NIOLockedValueBox<Result<HTTPOrWebSocket, Error>?>(nil)
		promise.futureResult.whenComplete { outcome in result.withLockedValue { $0 = outcome } }

		try channel.pipeline.syncOperations.addHandler(PlainHTTPFallbackHandler(idleTimeout: nil, promise: promise))

		let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
		try channel.writeInbound(HTTPServerRequestPart.head(head))

		guard case .success(let value) = result.withLockedValue({ $0 }), case .http = value else {
			XCTFail("expected .success(.http), got \(String(describing: result.withLockedValue({ $0 })))")
			return
		}
	}
}
