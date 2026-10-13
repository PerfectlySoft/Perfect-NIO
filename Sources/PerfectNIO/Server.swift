//
//  Server.swift
//  PerfectNIO
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2019 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//
// Phase 5: the async-native server API. Replaces the synchronous
// bind().listen()/stop()/wait() surface (and its async→sync bridge) with a
// structured-concurrency `Server`. The connection-handling serve loop itself
// lives in NIOAsyncHTTPHandler.swift (Phase 4) and is reused unchanged.
//

import NIO
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import NIOWebSocket
import NIOConcurrencyHelpers
import Foundation

typealias HTTPConnectionChannel = NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>
typealias WebSocketConnectionChannel = NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
// Each accepted connection resolves to one of these once the HTTP-upgrade decision is made.
// The server channel yields the *futures* so the accept loop never blocks on a slow handshake.
typealias HTTPServerChannel = NIOAsyncChannel<EventLoopFuture<HTTPOrWebSocket>, Never>

/// The outcome of the HTTP-upgrade negotiation for one connection.
enum HTTPOrWebSocket: Sendable {
	/// Plain HTTP. The box holds what resolving the first request's route produced, if that
	/// request was a WebSocket handshake to a `webSocket(...)` route that didn't upgrade.
	case http(HTTPConnectionChannel, HandshakeBox?)
	case websocket(WebSocketConnectionChannel, WebSocketHandler, [WebSocketOption])
}

/// What running a `webSocket(...)` route for a handshake produced. Written by the pre-upgrade
/// router and read by the upgrader and, when the connection isn't upgraded, by its first HTTP
/// dispatch, which serves the result instead of running the route a second time.
enum HandshakeResolution: Sendable {
	/// The handler, its options, and the subprotocol the route declared.
	case webSocket(WebSocketHandler, [WebSocketOption], String?)
	/// The route threw (a refused handshake: statusCheck, an auth check) or produced an output
	/// that isn't a WebSocket (a flagged parent `dir`'d into a plain child).
	case served(Result<(RouteContext, HTTPOutput), any Error>)

	var webSocket: (WebSocketHandler, [WebSocketOption])? {
		if case .webSocket(let handler, let options, _) = self { return (handler, options) }
		return nil
	}

	/// The extra 101 response headers for `request`, or nil to refuse the upgrade. Selects the
	/// route's subprotocol when the client offers it (RFC 6455 §4.2.2); browsers fail a
	/// connection whose 101 names none of the subprotocols they offered.
	func upgradeHeaders(for request: HTTPRequestHead) -> HTTPHeaders? {
		guard case .webSocket(_, _, let subprotocol) = self else { return nil }
		var headers = HTTPHeaders()
		let offered = request.headers[canonicalForm: "sec-websocket-protocol"].map {
			$0.trimmingCharacters(in: .whitespaces)
		}
		if let subprotocol, offered.contains(subprotocol) {
			headers.add(name: "Sec-WebSocket-Protocol", value: subprotocol)
		}
		return headers
	}
}

/// One per connection; see `HandshakeResolution`.
typealias HandshakeBox = NIOLockedValueBox<HandshakeResolution?>

/// An HTTP(S) server for a set of routes.
///
/// ```swift
/// // Long-running:
/// try await Server(routes: myRoutes, port: 8080).run()
///
/// // Scoped (tests / programmatic):
/// try await Server(routes: myRoutes, port: 8080).withServer { port in
///     // ...make requests against `port`; server shuts down when this returns...
/// }
/// ```
public struct Server: Sendable {
	/// The routes this server will serve.
	public var routes: Routes<HTTPRequest, HTTPOutput>
	/// The host/interface to bind on. Defaults to all interfaces.
	public var host: String
	/// The port to bind on. Pass 0 for an OS-assigned ephemeral port (see `withServer`'s argument).
	public var port: Int
	/// TLS configuration. When non-nil the server speaks HTTPS.
	public var tls: TLSConfiguration?
	/// Live-updatable per-domain TLS manager. Enables multi-tenant SNI: dozens of domains,
	/// each with its own cert, hot-swappable without restarting the server. When both `tls`
	/// and `tlsManager` are set, `tlsManager` takes precedence.
	public var tlsManager: TLSContextManager?
	/// Closes an idle connection after this long. `nil` disables the timeout.
	///
	/// It runs from the moment a connection is accepted. While no response is pending (before
	/// the first request, while a request head or body is arriving, between keep-alive
	/// requests) the connection is idle when nothing has been read for this long; that covers a
	/// client that sends nothing, a stalled TLS handshake and a request that never finishes.
	///
	/// While a response is pending (the route is working, or the body is being sent) the
	/// connection is idle only when the client has stopped reading: the response is backed up
	/// and neither a write has completed nor the kernel reported any of it leaving the send
	/// buffer for this long. A slow but steady download, a long poll or a stream of events is
	/// not cut off. TCP delivers in bursts (a receiver reopens its window only after reading a
	/// good part of its buffer), so keep the timeout well above a few seconds; the default 60 s
	/// is. Once the client has closed its side, a connection whose response is pending is also
	/// closed when nothing has been written for this long, so a client that disconnects from a
	/// slow route doesn't pin the socket (a client that half-closes and then waits longer than
	/// this for its response is cut too). A route that never returns keeps a connected client's
	/// connection open. The timeout is removed when a connection upgrades to WebSocket.
	///
	/// It resets on every byte, so a client that trickles a request slowly isn't bounded by it;
	/// there is no whole-request deadline. Checks run every quarter of the timeout, so a
	/// connection closes between 1 and 1.25 times the timeout after it went idle.
	public var idleTimeout: TimeAmount?
	/// Number of server sockets to open on the same port via `SO_REUSEPORT` (kernel load-balances
	/// accepts across them). 1 = a single socket with no `SO_REUSEPORT`.
	public var reusePortCount: Int
	/// When `true`, always sets `SO_REUSEPORT` on this server's listening socket, independent of
	/// `reusePortCount` — lets a second, independent OS process bind the identical port while this
	/// one is still running (a graceful hand-off restart: the new process starts accepting before
	/// the old one stops), without opening multiple sockets within *this* process. Defaults to
	/// `false`, preserving the existing exclusive-bind behavior for a single socket.
	public var alwaysReusePort: Bool
	/// The largest request body, in bytes, the server will accept. `nil` means no limit.
	///
	/// The whole body (multipart uploads included) is held in memory before the route runs, so
	/// this bounds the memory one request can use. A request whose `Content-Length` is larger is
	/// refused with 413 Payload Too Large before any of its body is read; a chunked body is
	/// refused as soon as it grows past the limit. The connection is closed after a 413.
	/// Defaults to `Server.defaultMaxRequestBodySize` (10 MiB). Raise it for servers that take
	/// large uploads. A negative value is treated as 0 (only empty bodies are accepted).
	///
	/// The limit is per request. Every open connection can hold up to this much at once, and
	/// the idle timeout resets on each byte received, so total memory also depends on how many
	/// slow uploads are in flight.
	public var maxRequestBodySize: Int?

	/// The default for `maxRequestBodySize`: 10 MiB.
	public static let defaultMaxRequestBodySize = 10 * 1024 * 1024

	public init(routes: Routes<HTTPRequest, HTTPOutput>,
	            host: String = "0.0.0.0",
	            port: Int,
	            tls: TLSConfiguration? = nil,
	            idleTimeout: TimeAmount? = .seconds(60),
	            reusePortCount: Int = 1,
	            alwaysReusePort: Bool = false,
	            maxRequestBodySize: Int? = Server.defaultMaxRequestBodySize) {
		self.routes = routes
		self.host = host
		self.port = port
		self.tls = tls
		self.idleTimeout = idleTimeout
		self.reusePortCount = reusePortCount
		self.alwaysReusePort = alwaysReusePort
		self.maxRequestBodySize = maxRequestBodySize
	}

	/// Bind and serve until the surrounding task is cancelled, then gracefully drain in-flight
	/// connections and shut down the owned EventLoopGroup. Intended for an application's entry point.
	public func run() async throws {
		try await serve { _ in
			// Park until the surrounding task is cancelled — cancellation is the shutdown signal.
			// Task.sleep throws on cancellation, so the loop exits promptly and serve() tears down.
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
			}
		}
	}

	/// Bind, invoke `body` once the server is listening (passing the actually-bound port), then
	/// shut the server down — on normal return, on a thrown error, or on cancellation. The
	/// structured-concurrency replacement for start/stop; teardown (including EventLoopGroup
	/// shutdown) is automatic and awaited.
	@discardableResult
	nonisolated(nonsending)
	public func withServer<R>(_ body: (_ boundPort: Int) async throws -> R) async throws -> R {
		// Captured out of the serve task; only read after `body` runs (i.e. after binding).
		let resultBox = NIOLockedValueBox<Result<R, Error>?>(nil)
		try await serve { boundPort in
			let outcome: Result<R, Error>
			do { outcome = .success(try await body(boundPort)) }
			catch { outcome = .failure(error) }
			resultBox.withLockedValue { $0 = outcome }
		}
		// serve() only returns after onReady completed (or binding failed before it ran).
		guard let result = resultBox.withLockedValue({ $0 }) else {
			throw ServerError("server stopped before it finished binding on port \(port)")
		}
		return try result.get()
	}

	// MARK: - Core

	/// Owns the full server lifecycle: bind N channels, run their accept loops, invoke `onReady`
	/// once listening, and tear everything down (channels + EventLoopGroup) when `onReady` returns.
	nonisolated(nonsending)
	private func serve(onReady: (_ boundPort: Int) async throws -> Void) async throws {
		_ = processGlobalInit
		let finder = try RouteFinderDual(routes)
		let resolvedManager: TLSContextManager?
		if let manager = tlsManager {
			resolvedManager = manager
		} else if let config = tls {
			resolvedManager = try TLSContextManager(default: config)
		} else {
			resolvedManager = nil
		}
		let isTLS = resolvedManager != nil
		let maxBodySize = maxRequestBodySize.map { max(0, $0) }
		let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

		func shutdown() async { try? await group.shutdownGracefully() }

		do {
			let channels = try await bind(group: group, tlsManager: resolvedManager, finder: finder, isTLS: isTLS)
			let boundPort = channels.first?.channel.localAddress?.port ?? port
			try await withThrowingTaskGroup(of: Void.self) { acceptors in
				for channel in channels {
					acceptors.addTask {
						await Server.runAcceptLoop(channel, finder: finder, isTLS: isTLS, maxBodySize: maxBodySize)
					}
				}
				// Run the caller's work, then stop accepting. A throw here auto-cancels the
				// acceptor tasks; on success we cancel them explicitly.
				do {
					try await onReady(boundPort)
				} catch {
					acceptors.cancelAll()
					throw error
				}
				acceptors.cancelAll()
			}
			await shutdown()
		} catch {
			await shutdown()
			throw error
		}
	}

	/// Binds `reusePortCount` server channels on the configured host/port. Each child channel is
	/// configured with an HTTP pipeline that can upgrade to WebSocket (see `configureUpgrade`).
	private func bind(group: MultiThreadedEventLoopGroup,
	                  tlsManager: TLSContextManager?,
	                  finder: any RouteFinder,
	                  isTLS: Bool) async throws -> [HTTPServerChannel] {
		let count = max(1, reusePortCount)
		let reusePort = count > 1 || alwaysReusePort
		let idle = idleTimeout
		let host = self.host
		let port = self.port

		var channels: [HTTPServerChannel] = []
		channels.reserveCapacity(count)
		for _ in 0..<count {
			var bootstrap = ServerBootstrap(group: group)
				.serverChannelOption(ChannelOptions.backlog, value: 256)
				.serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
			if reusePort {
				bootstrap = bootstrap.serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEPORT), value: 1)
			}
			bootstrap = bootstrap
				.childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
				.childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
				.childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
			let channel = try await bootstrap.bind(host: host, port: port) { childChannel in
				childChannel.eventLoop.makeCompletedFuture {
					// The idle timeout runs from accept, ahead of TLS and HTTP, so a client that
					// sends nothing or never finishes its request head is closed too. A WebSocket
					// upgrade removes it (see IdleTimeout.remove).
					let idleHandlers = try idle.map { try IdleTimeout.add(to: childChannel, timeout: $0) }
					if let manager = tlsManager {
						try childChannel.pipeline.syncOperations.addHandler(SNIPeekHandler(manager: manager))
					}
					let outcome: EventLoopFuture<HTTPOrWebSocket>
					if #available(macOS 13, *) {
						outcome = try Server.configureUpgrade(channel: childChannel, finder: finder, isTLS: isTLS, idleHandlers: idleHandlers)
					} else {
						outcome = try Server.configureUpgradeFallback(channel: childChannel, finder: finder, isTLS: isTLS, idleHandlers: idleHandlers)
					}
					// Until the first request is routed nothing owns the channel, so an error there
					// (a request the HTTP parser rejected, after NIO's 400; a TLS failure) closes
					// it here. Such connections used to stay open indefinitely.
					let closer = CloseOnErrorHandler()
					try childChannel.pipeline.syncOperations.addHandler(closer)
					outcome.whenComplete { result in
						switch result {
						case .success:
							childChannel.pipeline.syncOperations.removeHandler(closer, promise: nil)
						case .failure:
							childChannel.close(promise: nil)
						}
					}
					return outcome
				}
			}
			channels.append(channel)
		}
		return channels
	}

	/// Configures the child channel's HTTP pipeline with a WebSocket upgrader. Returns the future
	/// that resolves to either a normal HTTP connection or an upgraded WebSocket connection.
	///
	/// `NIOTypedHTTPServerUpgradeHandler` needs macOS 13.0 — below that, falls back to
	/// `configureUpgradeFallback`, which does the same job with NIOHTTP1's older non-generic
	/// `HTTPServerUpgradeHandler`, so this file's own floor doesn't force 13.0 on every caller.
	@available(macOS 13, *)
	private static func configureUpgrade(channel: Channel,
	                                     finder: any RouteFinder,
	                                     isTLS: Bool,
	                                     idleHandlers: IdleTimeout.Handlers?) throws -> EventLoopFuture<HTTPOrWebSocket> {
		// Populated by the pre-upgrade router (below) before the typed upgrader runs, so the
		// upgrader and its pipeline handler can read the resolved handler synchronously.
		let resolved = HandshakeBox(nil)

		let upgrader = NIOTypedWebSocketServerUpgrader<HTTPOrWebSocket>(
			shouldUpgrade: { channel, head in
				// The router only forwards a handshake here (Upgrade header intact) once it has
				// confirmed the path is a WebSocket route and stored the handler — so accept iff
				// that happened. The upgrader validates Sec-WebSocket-* and computes the accept key.
				let headers = resolved.withLockedValue { $0?.upgradeHeaders(for: head) }
				return channel.eventLoop.makeSucceededFuture(headers)
			},
			upgradePipelineHandler: { channel, _ in
				channel.eventLoop.makeCompletedFuture {
					// WebSocket connections are long-lived and manage their own liveness.
					if let idleHandlers { IdleTimeout.remove(idleHandlers, from: channel) }
					let wsChannel = try WebSocketConnectionChannel(wrappingChannelSynchronously: channel)
					let noop: WebSocketHandler = { _ in }
					let (handler, options) = resolved.withLockedValue { $0?.webSocket } ?? (noop, [])
					return HTTPOrWebSocket.websocket(wsChannel, handler, options)
				}
			}
		)

		let upgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration<HTTPOrWebSocket>(
			upgraders: [upgrader],
			notUpgradingCompletionHandler: { channel in
				channel.eventLoop.makeCompletedFuture {
					HTTPOrWebSocket.http(try HTTPConnectionChannel(wrappingChannelSynchronously: channel), resolved)
				}
			}
		)

		// We build the upgradable HTTP pipeline by hand (rather than
		// `configureUpgradableHTTPServerPipeline`) so the pre-upgrade router can sit *between* the
		// request decoder and the upgrade handler. This is what makes a refused upgrade behave
		// correctly per RFC 6455 §4.2.2: the router strips the `Upgrade` header for non-WebSocket
		// paths, so NIO serves the request as ordinary HTTP and the route's real status (e.g. 404)
		// is returned, instead of the request being discarded by the upgrader.
		let sync = channel.pipeline.syncOperations
		// Framing headers are set by NIOAsyncHTTPServer.writeResponse, which knows the request
		// method: the encoder's automatic framing doesn't (configureHTTPServerPipeline feeds it
		// that, a hand-built pipeline can't), so it chunked HEAD responses of unknown length.
		let responseEncoder = HTTPResponseEncoder(configuration: .withoutAutomaticFraming)
		let requestDecoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
		var extraHTTPHandlers: [RemovableChannelHandler] = [requestDecoder]
		try sync.addHandler(responseEncoder)
		try sync.addHandler(requestDecoder)
		try IdleTimeout.addTracker(idleHandlers, after: requestDecoder, to: sync, extraHTTPHandlers: &extraHTTPHandlers)
		let pipeliningHandler = HTTPServerPipelineHandler()
		try sync.addHandler(pipeliningHandler)
		extraHTTPHandlers.append(pipeliningHandler)
		let headerValidator = NIOHTTPResponseHeadersValidator()
		try sync.addHandler(headerValidator)
		extraHTTPHandlers.append(headerValidator)
		let errorHandler = HTTPServerProtocolErrorHandler()
		try sync.addHandler(errorHandler)
		extraHTTPHandlers.append(errorHandler)

		try sync.addHandler(WebSocketUpgradeRouter(finder: finder, isTLS: isTLS, resolved: resolved))

		let upgradeHandler = NIOTypedHTTPServerUpgradeHandler(
			httpEncoder: responseEncoder,
			extraHTTPHandlers: extraHTTPHandlers,
			upgradeConfiguration: upgradeConfiguration
		)
		try sync.addHandler(upgradeHandler)
		return upgradeHandler.upgradeResultFuture
	}

	/// Pre-13.0 fallback for `configureUpgrade`, built on NIOHTTP1's older non-generic
	/// `HTTPServerUpgradeHandler`/`NIOWebSocketServerUpgrader` instead of the typed API. Same pipeline
	/// shape and the same `WebSocketUpgradeRouter` pre-upgrade router, but since the non-generic
	/// handler has no `upgradeResultFuture` of its own, the two outcomes (upgraded / not upgrading)
	/// are unified into one `HTTPOrWebSocket` via a hand-built promise:
	///   - on a successful WebSocket upgrade, `upgradePipelineHandler` below fulfills it directly;
	///   - on a plain HTTP request, `HTTPServerUpgradeHandler` forwards the request unmodified to
	///     `PlainHTTPFallbackHandler`, added at the tail, which fulfills it there.
	/// These two paths are mutually exclusive per connection, matching the typed handler's own
	/// upgrade-or-not decision, so the promise is always fulfilled exactly once.
	private static func configureUpgradeFallback(channel: Channel,
	                                             finder: any RouteFinder,
	                                             isTLS: Bool,
	                                             idleHandlers: IdleTimeout.Handlers?) throws -> EventLoopFuture<HTTPOrWebSocket> {
		let resolved = HandshakeBox(nil)
		let promise = channel.eventLoop.makePromise(of: HTTPOrWebSocket.self)

		let sync = channel.pipeline.syncOperations
		// Framing headers are set by NIOAsyncHTTPServer.writeResponse, which knows the request
		// method: the encoder's automatic framing doesn't (configureHTTPServerPipeline feeds it
		// that, a hand-built pipeline can't), so it chunked HEAD responses of unknown length.
		let responseEncoder = HTTPResponseEncoder(configuration: .withoutAutomaticFraming)
		let requestDecoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
		var extraHTTPHandlers: [RemovableChannelHandler] = [requestDecoder]
		try sync.addHandler(responseEncoder)
		try sync.addHandler(requestDecoder)
		try IdleTimeout.addTracker(idleHandlers, after: requestDecoder, to: sync, extraHTTPHandlers: &extraHTTPHandlers)
		let pipeliningHandler = HTTPServerPipelineHandler()
		try sync.addHandler(pipeliningHandler)
		extraHTTPHandlers.append(pipeliningHandler)
		let headerValidator = NIOHTTPResponseHeadersValidator()
		try sync.addHandler(headerValidator)
		extraHTTPHandlers.append(headerValidator)
		let errorHandler = HTTPServerProtocolErrorHandler()
		try sync.addHandler(errorHandler)
		extraHTTPHandlers.append(errorHandler)

		try sync.addHandler(WebSocketUpgradeRouter(finder: finder, isTLS: isTLS, resolved: resolved))

		// Constructed now (captured by wsUpgrader below) but added to the pipeline only after
		// upgradeHandler, so it sits downstream and only ever sees data via HTTPServerUpgradeHandler's
		// not-upgrading forwarding path (see its doc comment below).
		let fallbackHandler = PlainHTTPFallbackHandler(promise: promise, handshake: resolved)

		let wsUpgrader = NIOWebSocketServerUpgrader(
			shouldUpgrade: { channel, head in
				let headers = resolved.withLockedValue { $0?.upgradeHeaders(for: head) }
				return channel.eventLoop.makeSucceededFuture(headers)
			},
			upgradePipelineHandler: { channel, _ in
				// Remove the still-present, never-triggered plain-HTTP tail handler first: it would
				// otherwise sit downstream of the WebSocket frame codec added next and misinterpret
				// the first inbound WebSocketFrame as an HTTPServerRequestPart. Suppressed first so
				// its own handlerRemoved doesn't race a spurious failure against the real success
				// below.
				fallbackHandler.suppressResolution()
				if let idleHandlers { IdleTimeout.remove(idleHandlers, from: channel) }
				return channel.pipeline.syncOperations.removeHandler(fallbackHandler)
					.flatMap {
						channel.eventLoop.makeCompletedFuture {
							let wsChannel = try WebSocketConnectionChannel(wrappingChannelSynchronously: channel)
							let noop: WebSocketHandler = { _ in }
							let (handler, options) = resolved.withLockedValue { $0?.webSocket } ?? (noop, [])
							promise.succeed(.websocket(wsChannel, handler, options))
						}
					}
			}
		)

		let upgradeHandler = HTTPServerUpgradeHandler(
			upgraders: [wsUpgrader],
			httpEncoder: responseEncoder,
			extraHTTPHandlers: extraHTTPHandlers,
			upgradeCompletionHandler: { _ in }
		)
		try sync.addHandler(upgradeHandler)
		try sync.addHandler(fallbackHandler)

		return promise.futureResult
	}

	/// Resolves a request against the routes and, if it lands on a `webSocket(...)` route,
	/// returns that route's handler + options. Returns nil for any non-WebSocket route.
	///
	/// Only routes flagged at registration as WebSocket endpoints are run here. Any other route is
	/// left untouched so it runs exactly once, as plain HTTP with the real body, after the
	/// Upgrade headers are stripped.
	///
	/// A WebSocket route that throws, or produces something other than a WebSocket, has its
	/// result kept so the connection's first HTTP dispatch can serve it without running the
	/// route again.
	fileprivate static func resolveWebSocket(_ request: NIOAsyncHTTPRequest,
	                                         finder: any RouteFinder) async -> HandshakeResolution? {
		guard let route = finder.route(request.method, request.path), route.isWebSocket else { return nil }
		let ctx = RouteContext(request: request, uri: request.path)
		do {
			let (finalCtx, output) = try await route.handler(ctx, request)
			if let wsOutput = output as? WebSocketUpgradeHTTPOutput {
				return .webSocket(wsOutput.handler, wsOutput.options, wsOutput.subprotocol)
			}
			return .served(.success((finalCtx, output)))
		} catch {
			return .served(.failure(error))
		}
	}

	/// Accept loop for one server channel: each accepted connection is handled in its own child
	/// task so slow clients never block accepts. Returns when the channel closes or on cancellation.
	///
	/// `withThrowingDiscardingTaskGroup` needs macOS 14.0 — below that, falls back to a
	/// bounded regular task group (see `runAcceptLoopBounded` below) so this file's own floor
	/// doesn't force 14.0 on every caller. See the `taplin/Perfect-Lasso` repo's
	/// `Documentation/macos-deployment-targets.md` for the full cross-repo investigation.
	private static func runAcceptLoop(_ serverChannel: HTTPServerChannel,
	                                  finder: any RouteFinder,
	                                  isTLS: Bool,
	                                  maxBodySize: Int?) async {
		do {
			if #available(macOS 14, *) {
				try await withThrowingDiscardingTaskGroup { connections in
					try await serverChannel.executeThenClose { inbound in
						for try await upgradeResult in inbound {
							connections.addTask {
								await Server.handleConnection(upgradeResult, finder: finder, isTLS: isTLS,
								                              maxBodySize: maxBodySize)
							}
						}
					}
				}
			} else {
				try await Server.runAcceptLoopBounded(serverChannel, finder: finder, isTLS: isTLS,
				                                      maxBodySize: maxBodySize)
			}
		} catch {
			// Server channel closed (cancellation / shutdown) or the accept loop failed.
		}
	}

	/// Pre-macOS-14 fallback: a regular task group has no way to release a finished child's
	/// result without the body calling `next()`, so an unbounded add-and-forget loop here
	/// would retain bookkeeping for every connection accepted over the server's whole
	/// lifetime. Capping in-flight connections and calling `next()` to free a slot before
	/// accepting past the cap keeps memory bounded; new connections simply queue at the
	/// kernel/NIO level until a slot frees.
	private static func runAcceptLoopBounded(_ serverChannel: HTTPServerChannel,
	                                         finder: any RouteFinder,
	                                         isTLS: Bool,
	                                         maxBodySize: Int?) async throws {
		let maxConcurrentConnections = 4096
		try await withThrowingTaskGroup(of: Void.self) { connections in
			var active = 0
			try await serverChannel.executeThenClose { inbound in
				for try await upgradeResult in inbound {
					if active >= maxConcurrentConnections {
						_ = try await connections.next()
						active -= 1
					}
					connections.addTask {
						await Server.handleConnection(upgradeResult, finder: finder, isTLS: isTLS,
						                              maxBodySize: maxBodySize)
					}
					active += 1
				}
			}
		}
	}

	/// Awaits one connection's upgrade outcome and dispatches it to the right driver.
	private static func handleConnection(_ upgradeResult: EventLoopFuture<HTTPOrWebSocket>,
	                                     finder: any RouteFinder,
	                                     isTLS: Bool,
	                                     maxBodySize: Int?) async {
		do {
			switch try await upgradeResult.get() {
			case .http(let channel, let handshake):
				await NIOAsyncHTTPServer.handleConnection(channel, finder: finder, isTLS: isTLS, maxBodySize: maxBodySize,
				                                          handshake: handshake?.withLockedValue { $0 })
			case .websocket(let channel, let handler, let options):
				await WebSocketRunner.run(channel, handler: handler, options: options)
			}
		} catch {
			// Upgrade negotiation failed or the connection errored before producing a result.
		}
	}
}

// MARK: - HTTP→HTTPS redirect

extension Server {
	/// Creates a redirect-only server on `port` (default 80).
	///
	/// Every inbound HTTP request — regardless of path, method, or body — receives a
	/// permanent redirect to the equivalent `https://` URL. The default 308 status
	/// preserves the HTTP method (POST stays POST). Pass `.movedPermanently` (301) only
	/// when legacy clients that pre-date RFC 7538 must be supported.
	///
	/// Usage:
	/// ```swift
	/// async let _ = Server.httpRedirect().run()
	/// async let _ = Server(routes: appRoutes, port: 443, tlsManager: certManager).run()
	/// try await withThrowingTaskGroup(of: Void.self) { group in
	///     group.addTask { try await Server.httpRedirect().run() }
	///     group.addTask { try await httpsServer.run() }
	///     try await group.waitForAll()
	/// }
	/// ```
	public static func httpRedirect(
		port: Int = 80,
		status: HTTPResponseStatus = .permanentRedirect
	) -> Server {
		let routes = root().trailing { (req: any HTTPRequest, _: String) -> HTTPOutput in
			let host = req.headers.first(name: "host") ?? ""
			return RedirectOutput(to: "https://\(host)\(req.uri)", status: status)
		}
		return Server(routes: routes, port: port)
	}
}

/// An error originating from the server lifecycle.
public struct ServerError: Error, CustomStringConvertible {
	public let description: String
	init(_ description: String) { self.description = description }
}

/// Closes the connection on any error that reaches the end of the pipeline before the first
/// request has been routed. Removed once it has. `@unchecked Sendable`: only touched on its
/// channel's event loop.
final class CloseOnErrorHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
	typealias InboundIn = NIOAny
	func errorCaught(context: ChannelHandlerContext, error: Error) {
		context.close(promise: nil)
		context.fireErrorCaught(error)
	}
}

extension HTTPResponseEncoder.Configuration {
	/// See `NIOAsyncHTTPServer.writeResponse`, which sets the framing headers instead.
	static var withoutAutomaticFraming: Self {
		var configuration = Self()
		configuration.automaticallySetFramingHeaders = false
		return configuration
	}
}

/// The idle timeout installed on every accepted connection. See `Server.idleTimeout`.
enum IdleTimeout {
	/// `@unchecked Sendable`: created, and only used, on the channel's event loop.
	final class Handlers: @unchecked Sendable {
		let timer: IdleTimeoutHandler
		init(timeout: TimeAmount) {
			timer = IdleTimeoutHandler(timeout: timeout)
		}
	}

	/// Adds the timer at the front of the pipeline, ahead of TLS and HTTP, so it measures raw
	/// reads and writes. An `HTTPExchangeTracker` in the HTTP pipeline tells it about requests
	/// and responses (see `addTracker`).
	static func add(to channel: Channel, timeout: TimeAmount) throws -> Handlers {
		let handlers = Handlers(timeout: timeout)
		try channel.pipeline.syncOperations.addHandler(handlers.timer, position: .first)
		return handlers
	}

	/// Adds an `HTTPExchangeTracker` right after the HTTP request decoder, so it sees request
	/// and response parts. It is added with or without an idle timeout (the connection loop
	/// also waits on it before closing) and is one of the upgrader's extra HTTP handlers,
	/// removed on a WebSocket upgrade.
	static func addTracker(_ handlers: Handlers?, after decoder: ChannelHandler,
	                       to sync: ChannelPipeline.SynchronousOperations,
	                       extraHTTPHandlers: inout [RemovableChannelHandler]) throws {
		let tracker = HTTPExchangeTracker(timer: handlers?.timer)
		try sync.addHandler(tracker, position: .after(decoder))
		extraHTTPHandlers.append(tracker)
	}

	/// Called on the event loop when a connection is upgraded to WebSocket.
	static func remove(_ handlers: Handlers, from channel: Channel) {
		channel.pipeline.syncOperations.removeHandler(handlers.timer, promise: nil)
	}
}

/// Closes an idle connection.
///
/// While no response is pending (before the first request, while a request arrives, between
/// keep-alive requests) the connection is idle when nothing has been read for `timeout`.
///
/// While a response is pending the route is working or the response is being sent, which can
/// take as long as it takes (a slow download, a long poll, server-sent events). The connection
/// is then idle only when the response is backed up (the channel isn't writable) and has made
/// no progress for `timeout`. Progress is a completed write (writes are passed on in slices of
/// `sliceSize`, so a steady reader completes one often) or the kernel reporting that more of
/// the response has left its send buffer, since the kernel can absorb a large part of a
/// response and wake the server only in big batches. A client that has stopped reading makes
/// neither, and is closed.
///
/// Once the client has closed its side (`inputClosed`), the connection is also closed when
/// nothing has been written for `timeout`, writable or not: otherwise a client that sent a
/// request to a slow route and went away would pin the socket until the route finished. (A
/// client that only half-closes and waits longer than the timeout for its response is cut too.)
///
/// Sits first in the pipeline. `@unchecked Sendable`: only touched on its channel's event loop.
final class IdleTimeoutHandler: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
	typealias InboundIn = NIOAny
	typealias InboundOut = NIOAny
	typealias OutboundIn = IOData
	typealias OutboundOut = IOData

	/// Writes larger than this are passed on in slices of this size, so a slow but steady
	/// reader completes a write at least every `sliceSize` bytes rather than once per body chunk.
	static let sliceSize = 16 * 1024
	/// Kernel-reported progress smaller than this (a zero-window probe) doesn't count.
	static let minimumKernelProgress: UInt64 = 1024

	private let timeout: TimeAmount
	private var lastRead = NIODeadline.now()
	private var lastProgress = NIODeadline.now()
	private var responsesPending = 0
	private var inputClosed = false
	private var kernelSent: UInt64?
	private var check: RepeatedTask?

	init(timeout: TimeAmount) {
		self.timeout = timeout
	}

	/// A request has been fully received; its response is now pending.
	func requestEnded() {
		responsesPending += 1
	}

	/// A response has been written to the socket. With none pending, the read-idle clock restarts.
	func responseEnded() {
		responsesPending = max(0, responsesPending - 1)
		if responsesPending == 0 {
			lastRead = .now()
		}
	}

	func handlerAdded(context: ChannelHandlerContext) {
		lastRead = .now()
		lastProgress = .now()
		let interval = TimeAmount.nanoseconds(max(timeout.nanoseconds / 4, 1_000_000))
		let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
		check = context.eventLoop.scheduleRepeatedTask(initialDelay: interval, delay: interval) { [weak self] _ in
			self?.closeIfIdle(context: bound.value)
		}
	}

	func handlerRemoved(context: ChannelHandlerContext) {
		check?.cancel()
		check = nil
	}

	func channelInactive(context: ChannelHandlerContext) {
		check?.cancel()
		check = nil
		context.fireChannelInactive()
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		lastRead = .now()
		context.fireChannelRead(data)
	}

	func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
		if let event = event as? ChannelEvent, event == .inputClosed, !inputClosed {
			inputClosed = true
			// Restart the clock: from here only written progress keeps the connection.
			lastProgress = .now()
		}
		context.fireUserInboundEventTriggered(event)
	}

	func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
		guard case .byteBuffer(var buffer) = Self.unwrapOutboundIn(data), buffer.readableBytes > Self.sliceSize else {
			context.write(data, promise: tracking(promise, context: context))
			return
		}
		while buffer.readableBytes > Self.sliceSize, let slice = buffer.readSlice(length: Self.sliceSize) {
			context.write(Self.wrapOutboundOut(.byteBuffer(slice)), promise: tracking(nil, context: context))
		}
		context.write(Self.wrapOutboundOut(.byteBuffer(buffer)), promise: tracking(promise, context: context))
	}

	/// A promise for a write that records its completion as progress, cascading to `promise`.
	private func tracking(_ promise: EventLoopPromise<Void>?, context: ChannelHandlerContext) -> EventLoopPromise<Void> {
		let written = promise ?? context.eventLoop.makePromise()
		written.futureResult.assumeIsolated().whenSuccess { [weak self] in
			self?.lastProgress = .now()
		}
		return written
	}

	private func closeIfIdle(context: ChannelHandlerContext) {
		let now = NIODeadline.now()
		let idle: Bool
		if responsesPending > 0 {
			if !context.channel.isWritable {
				sampleKernelProgress(context: context)
			}
			idle = (inputClosed || !context.channel.isWritable) && now - lastProgress >= timeout
		} else {
			idle = now - lastRead >= timeout
		}
		if idle {
			check?.cancel()
			check = nil
			context.close(promise: nil)
		}
	}

	/// Asks the kernel how much of the connection's output has left its send buffer, and counts
	/// an advance as progress.
	private func sampleKernelProgress(context: ChannelHandlerContext) {
		guard let provider = context.channel as? SocketOptionProvider else { return }
		let loop = context.eventLoop
		Self.kernelBytesSent(provider).hop(to: loop).assumeIsolated().whenSuccess { [weak self] sent in
			guard let self, let sent else { return }
			if let previous = self.kernelSent, sent >= previous + Self.minimumKernelProgress {
				self.lastProgress = .now()
			}
			if self.kernelSent.map({ sent >= $0 + Self.minimumKernelProgress || sent < $0 }) ?? true {
				self.kernelSent = sent
			}
		}
	}

	/// A counter of the connection's output that has left the kernel: bytes acknowledged by the
	/// peer on Linux, bytes transmitted (less retransmissions) on Darwin. Nil if unavailable.
	private static func kernelBytesSent(_ provider: SocketOptionProvider) -> EventLoopFuture<UInt64?> {
		#if canImport(Darwin)
		let info: EventLoopFuture<tcp_connection_info> = provider.unsafeGetSocketOption(
			level: SocketOptionLevel(IPPROTO_TCP), name: SocketOptionName(TCP_CONNECTION_INFO))
		return info.map { $0.tcpi_txbytes &- $0.tcpi_txretransmitbytes }.recover { _ in nil }
		#elseif os(Linux)
		// The kernel's struct tcp_info up to tcpi_bytes_acked (Linux 4.1+), which sits after 8
		// one-byte fields, 24 UInt32s and two UInt64s (offset 120). Glibc's declaration stops
		// earlier. An older kernel fills less, leaving the field 0, so no kernel progress is seen.
		struct TCPInfoPrefix: Sendable {
			var leading: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
			              UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) =
				(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
			var bytesAcked: UInt64 = 0
		}
		let info: EventLoopFuture<TCPInfoPrefix> = provider.unsafeGetSocketOption(
			level: SocketOptionLevel(IPPROTO_TCP), name: SocketOptionName(TCP_INFO))
		return info.map { $0.bytesAcked == 0 ? nil : $0.bytesAcked }.recover { _ in nil }
		#else
		return provider.eventLoop.makeSucceededFuture(nil)
		#endif
	}
}

/// Tells the `IdleTimeoutHandler` (if there is one) when a request has been received and when
/// its response has been written to the socket, and lets the connection loop wait for that
/// before it closes. `@unchecked Sendable`: only touched on its channel's event loop.
final class HTTPExchangeTracker: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
	typealias InboundIn = HTTPServerRequestPart
	typealias InboundOut = HTTPServerRequestPart
	typealias OutboundIn = HTTPServerResponsePart
	typealias OutboundOut = HTTPServerResponsePart

	private let timer: IdleTimeoutHandler?
	/// Completes when the last response's end has been written to the socket.
	private var lastEnd: EventLoopFuture<Void>?

	init(timer: IdleTimeoutHandler?) {
		self.timer = timer
	}

	/// Waits until every response part written so far has reached the socket (or failed).
	/// Closing a channel drops writes still queued in NIO, so a large response on a connection
	/// that closes after it (Connection: close, HTTP/1.0) lost its tail to a slow reader.
	static func flushed(_ channel: Channel) async {
		guard let tracker = try? await channel.pipeline.handler(type: HTTPExchangeTracker.self).get() else { return }
		let pending: EventLoopFuture<Void>?? = try? await channel.eventLoop.submit { tracker.lastEnd }.get()
		_ = try? await pending??.get()
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		if case .end = Self.unwrapInboundIn(data) {
			timer?.requestEnded()
		}
		context.fireChannelRead(data)
	}

	func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
		guard case .end = Self.unwrapOutboundIn(data) else {
			context.write(data, promise: promise)
			return
		}
		// The response is over once its last bytes have been written to the socket, not when
		// they were queued: until then the client is still reading it.
		let written = promise ?? context.eventLoop.makePromise()
		let timer = self.timer
		written.futureResult.assumeIsolated().whenComplete { _ in
			timer?.responseEnded()
		}
		lastEnd = written.futureResult
		context.write(data, promise: written)
	}
}

/// Terminal handler for `configureUpgradeFallback`'s pre-13.0 pipeline. `HTTPServerUpgradeHandler`
/// (the non-generic upgrader) has no `upgradeResultFuture`; instead it forwards a request's parts
/// downstream unmodified, exactly once it determines a connection is not upgrading, then removes
/// itself from the pipeline. This handler sits right after it and is therefore only ever reached via
/// that not-upgrading path — never on a successful WebSocket upgrade, since `wsUpgrader`'s
/// `upgradePipelineHandler` removes this handler first (see `configureUpgradeFallback`).
///
/// The first inbound part it ever sees is therefore always the start of a genuine plain-HTTP request:
/// it wraps the channel, fulfills the promise, forwards the part into the new wrap, and removes itself.
///
/// If the connection closes before either outcome happens (e.g. a health-check probe or TLS-handshake
/// failure that never sends a request), `HTTPServerUpgradeHandler` never forwards anything here and
/// `channelRead` never fires — with no other safety net the promise would simply never resolve,
/// hanging the accept loop's per-connection task forever. `handlerRemoved` closes that gap, mirroring
/// `NIOTypedHTTPServerUpgradeHandler`'s own `handlerRemoved`-driven `.failUpgradePromise` behavior.
/// `@unchecked Sendable`: lives on and is only touched on its channel's event loop.
final class PlainHTTPFallbackHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
	typealias InboundIn = HTTPServerRequestPart
	typealias InboundOut = HTTPServerRequestPart

	private let promise: EventLoopPromise<HTTPOrWebSocket>
	private let handshake: HandshakeBox?
	private var resolved = false

	init(promise: EventLoopPromise<HTTPOrWebSocket>, handshake: HandshakeBox? = nil) {
		self.promise = promise
		self.handshake = handshake
	}

	/// Called by `configureUpgradeFallback` right before it removes this handler as part of a
	/// successful WebSocket upgrade, whose own `upgradePipelineHandler` fulfills the promise
	/// separately. Without this, that removal would trigger `handlerRemoved` below while `resolved`
	/// is still `false`, racing a spurious failure against the real, slightly later success.
	func suppressResolution() {
		resolved = true
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		guard !resolved else {
			context.fireChannelRead(data)
			return
		}
		resolved = true
		do {
			let httpChannel = try HTTPConnectionChannel(wrappingChannelSynchronously: context.channel)
			promise.succeed(.http(httpChannel, handshake))
		} catch {
			promise.fail(error)
		}
		context.fireChannelRead(data)
		context.fireChannelReadComplete()
		context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
	}

	func handlerRemoved(context: ChannelHandlerContext) {
		guard !resolved else { return }
		resolved = true
		promise.fail(ChannelError.inputClosed)
	}
}

/// Sits between the HTTP request decoder and the typed WebSocket upgrade handler. For a request
/// that carries an `Upgrade: websocket` header, it resolves the route first:
///   - if the path is a real `webSocket(...)` route, it stores the handler and forwards the
///     handshake unchanged so the upgrade proceeds;
///   - otherwise it strips the WebSocket headers and forwards the request as ordinary HTTP, so the
///     route's natural response (e.g. 404) is returned — the spec-compliant behavior (RFC 6455
///     §4.2.2 / §1.3) and what mainstream WebSocket servers do.
///
/// This is necessary because NIO's typed upgrade handler discards a refused upgrade request rather
/// than serving it as HTTP, so the decision must be made before it sees the request.
/// `@unchecked Sendable`: lives on and is only touched on its channel's event loop.
///
/// While a route is being resolved, the router holds back `read()` so that whatever follows the
/// head (a body, pipelined requests) stays in the socket rather than piling up in `buffered`.
/// Otherwise a request with an `Upgrade: websocket` header could stream an unbounded body into
/// memory past `Server.maxRequestBodySize` for as long as resolution takes.
private final class WebSocketUpgradeRouter: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
	typealias InboundIn = HTTPServerRequestPart
	typealias InboundOut = HTTPServerRequestPart
	typealias OutboundIn = NIOAny
	typealias OutboundOut = NIOAny

	private enum State { case awaitingHead, resolving, passthrough }
	private var state: State = .awaitingHead
	private var buffered: [HTTPServerRequestPart] = []
	/// A `read()` arrived while resolving and was held back; issued in `flush`.
	private var readPending = false
	private let finder: any RouteFinder
	private let isTLS: Bool
	private let resolved: HandshakeBox

	init(finder: any RouteFinder, isTLS: Bool, resolved: HandshakeBox) {
		self.finder = finder
		self.isTLS = isTLS
		self.resolved = resolved
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		switch state {
		case .passthrough:
			context.fireChannelRead(data)
		case .resolving:
			buffered.append(Self.unwrapInboundIn(data))
		case .awaitingHead:
			let part = Self.unwrapInboundIn(data)
			guard case .head(var head) = part, Self.isWebSocketUpgrade(head) else {
				// Not a WebSocket handshake; this connection is plain HTTP from here on.
				state = .passthrough
				if case .head(var head) = part, head.headers.contains(name: "upgrade") {
					// Another protocol (h2c, …): NIO's upgrader has no upgrader for it and closed
					// the connection with no response. Serve the request as plain HTTP instead,
					// ignoring the offer (RFC 9110 §7.8 lets a server do that); it is the
					// connection's last, since NIO's parser stops after an upgrade request.
					Self.removeWebSocketHeaders(&head)
					context.fireChannelRead(Self.wrapInboundOut(.head(head)))
					return
				}
				context.fireChannelRead(data)
				return
			}
			guard Self.hasValidHandshakeFields(head), !RequestPath.hasFragment(head.uri),
			      !RequestPath.hasDotDotSegment(head.uri) else {
				// (A ".." path is answered 400 by the HTTP side, before any route runs.)
				// A handshake NIO's upgrader would refuse by closing the connection without a
				// word (no Sec-WebSocket-Key, a version other than 13). Serve it as plain HTTP
				// instead: a webSocket route answers 426 with Sec-WebSocket-Version: 13, any
				// other route its usual response. Either way the connection then closes.
				Self.removeWebSocketHeaders(&head)
				state = .passthrough
				context.fireChannelRead(Self.wrapInboundOut(.head(head)))
				return
			}
			state = .resolving
			buffered.append(part)
			resolve(context: context, head: head)
		}
	}

	func read(context: ChannelHandlerContext) {
		if state == .resolving {
			readPending = true
		} else {
			context.read()
		}
	}

	private func resolve(context: ChannelHandlerContext, head: HTTPRequestHead) {
		let boundContext = NIOLoopBoundBox(context, eventLoop: context.eventLoop)
		let request = NIOAsyncHTTPRequest(head: head, body: [], channel: context.channel, isTLS: isTLS)
		let finder = self.finder
		let resolved = self.resolved
		Task {
			let resolution = await Server.resolveWebSocket(request, finder: finder)
			boundContext.eventLoop.execute {
				resolved.withLockedValue { $0 = resolution }
				self.flush(context: boundContext.value, stripUpgrade: resolution?.webSocket == nil)
			}
		}
	}

	/// Re-fire the buffered handshake (optionally with WebSocket headers removed), then remove self.
	private func flush(context: ChannelHandlerContext, stripUpgrade: Bool) {
		for part in buffered {
			if stripUpgrade, case .head(var head) = part {
				Self.removeWebSocketHeaders(&head)
				context.fireChannelRead(Self.wrapInboundOut(.head(head)))
			} else {
				context.fireChannelRead(Self.wrapInboundOut(part))
			}
		}
		buffered.removeAll()
		context.fireChannelReadComplete()
		state = .passthrough
		if readPending {
			readPending = false
			context.read()
		}
		context.pipeline.syncOperations.removeHandler(self, promise: nil)
	}

	/// One Sec-WebSocket-Key and Sec-WebSocket-Version 13, as NIO's upgrader requires.
	private static func hasValidHandshakeFields(_ head: HTTPRequestHead) -> Bool {
		let keys = head.headers[canonicalForm: "sec-websocket-key"]
		let versions = head.headers[canonicalForm: "sec-websocket-version"]
		return keys.count == 1 && !keys[0].isEmpty && versions.count == 1 && versions[0] == "13"
	}

	private static func isWebSocketUpgrade(_ head: HTTPRequestHead) -> Bool {
		head.headers[canonicalForm: "upgrade"].contains { $0.lowercased() == "websocket" }
	}

	private static func removeWebSocketHeaders(_ head: inout HTTPRequestHead) {
		for name in ["Upgrade", "Sec-WebSocket-Key", "Sec-WebSocket-Version",
		             "Sec-WebSocket-Protocol", "Sec-WebSocket-Extensions"] {
			head.headers.remove(name: name)
		}
		// NIO's HTTP decoder has already stopped parsing this connection: it does that after any
		// request asking to upgrade, upgraded or not. So the request is served as the
		// connection's last: "close" replaces the "upgrade" token (and any keep-alive), the
		// response says "Connection: close" and the connection is closed after it. Keeping it
		// open used to drop the client's next request on the floor.
		let remaining = head.headers[canonicalForm: "connection"].filter {
			let token = $0.lowercased()
			return token != "upgrade" && token != "keep-alive"
		}
		head.headers.remove(name: "Connection")
		for value in remaining { head.headers.add(name: "Connection", value: String(value)) }
		head.headers.add(name: "Connection", value: "close")
	}
}

/// One-time process setup, run on first server bind: ignore SIGPIPE, ignore SIGXFSZ unless the
/// app has already set its own disposition for it, and raise the open-file limit.
///
/// SIGXFSZ: under an RLIMIT_FSIZE, a write past the limit (a large upload, see `MimeReader`)
/// raises SIGXFSZ, whose default action terminates the process. Ignored, the write fails with
/// EFBIG instead and the upload is refused with 413. This is process-wide: any code in the
/// process then gets EFBIG rather than being killed. An app that wants something else can set
/// SIGXFSZ itself before starting the server (that's kept) or after (that wins). As with
/// SIGPIPE, an ignored disposition is inherited by child processes across exec unless the code
/// that spawns them resets it.
private let processGlobalInit: Bool = {
	var sa = sigaction()
#if os(Linux)
	sa.__sigaction_handler.sa_handler = SIG_IGN
#else
	sa.__sigaction_u.__sa_handler = SIG_IGN
#endif
	sa.sa_flags = 0
	sigaction(SIGPIPE, &sa, nil)
	var current = sigaction()
	if sigaction(SIGXFSZ, nil, &current) == 0 && current.isDefaultDisposition {
		sigaction(SIGXFSZ, &sa, nil)
	}
	var rlmt = rlimit()
#if os(Linux)
	getrlimit(Int32(RLIMIT_NOFILE.rawValue), &rlmt)
	rlmt.rlim_cur = rlmt.rlim_max
	setrlimit(Int32(RLIMIT_NOFILE.rawValue), &rlmt)
#else
	getrlimit(RLIMIT_NOFILE, &rlmt)
	rlmt.rlim_cur = rlim_t(OPEN_MAX)
	setrlimit(RLIMIT_NOFILE, &rlmt)
#endif
	return true
}()

private extension sigaction {
	/// True if the handler is SIG_DFL. With SA_SIGINFO the same storage holds `sa_sigaction`,
	/// which is never null, so this also covers that case.
	var isDefaultDisposition: Bool {
#if os(Linux)
		__sigaction_handler.sa_handler == nil
#else
		__sigaction_u.__sa_handler == nil
#endif
	}
}
