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
	case http(HTTPConnectionChannel)
	case websocket(WebSocketConnectionChannel, WebSocketHandler, [WebSocketOption])
}

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
	/// Closes a connection after this much time with no inbound read. `nil` disables the timeout.
	///
	/// This bounds idle keep-alive connections (resource-exhaustion / basic slowloris defense).
	/// Note: it measures *reads*, so a route handler that takes longer than this to produce its
	/// first byte on an otherwise-quiet connection will have the connection closed — give streaming
	/// / long-poll endpoints a larger value or `nil`. Full slow-trickle slowloris mitigation
	/// (a whole-request deadline) is a separate, later hardening step.
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

	public init(routes: Routes<HTTPRequest, HTTPOutput>,
	            host: String = "0.0.0.0",
	            port: Int,
	            tls: TLSConfiguration? = nil,
	            idleTimeout: TimeAmount? = .seconds(60),
	            reusePortCount: Int = 1,
	            alwaysReusePort: Bool = false) {
		self.routes = routes
		self.host = host
		self.port = port
		self.tls = tls
		self.idleTimeout = idleTimeout
		self.reusePortCount = reusePortCount
		self.alwaysReusePort = alwaysReusePort
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
		let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

		func shutdown() async { try? await group.shutdownGracefully() }

		do {
			let channels = try await bind(group: group, tlsManager: resolvedManager, finder: finder, isTLS: isTLS)
			let boundPort = channels.first?.channel.localAddress?.port ?? port
			try await withThrowingTaskGroup(of: Void.self) { acceptors in
				for channel in channels {
					acceptors.addTask {
						await Server.runAcceptLoop(channel, finder: finder, isTLS: isTLS)
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
					if let manager = tlsManager {
						try childChannel.pipeline.syncOperations.addHandler(SNIPeekHandler(manager: manager))
					}
					if #available(macOS 13, *) {
						return try Server.configureUpgrade(channel: childChannel, finder: finder, isTLS: isTLS, idleTimeout: idle)
					} else {
						return try Server.configureUpgradeFallback(channel: childChannel, finder: finder, isTLS: isTLS, idleTimeout: idle)
					}
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
	                                     idleTimeout: TimeAmount?) throws -> EventLoopFuture<HTTPOrWebSocket> {
		// Populated by the pre-upgrade router (below) before the typed upgrader runs, so the
		// upgrader and its pipeline handler can read the resolved handler synchronously.
		let resolved = NIOLockedValueBox<(WebSocketHandler, [WebSocketOption])?>(nil)

		let upgrader = NIOTypedWebSocketServerUpgrader<HTTPOrWebSocket>(
			shouldUpgrade: { channel, _ in
				// The router only forwards a handshake here (Upgrade header intact) once it has
				// confirmed the path is a WebSocket route and stored the handler — so accept iff
				// that happened. The upgrader validates Sec-WebSocket-* and computes the accept key.
				let accept = resolved.withLockedValue { $0 } != nil
				return channel.eventLoop.makeSucceededFuture(accept ? HTTPHeaders() : nil)
			},
			upgradePipelineHandler: { channel, _ in
				channel.eventLoop.makeCompletedFuture {
					let wsChannel = try WebSocketConnectionChannel(wrappingChannelSynchronously: channel)
					let noop: WebSocketHandler = { _ in }
					let (handler, options) = resolved.withLockedValue { $0 } ?? (noop, [])
					return HTTPOrWebSocket.websocket(wsChannel, handler, options)
				}
			}
		)

		let upgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration<HTTPOrWebSocket>(
			upgraders: [upgrader],
			notUpgradingCompletionHandler: { channel in
				channel.eventLoop.makeCompletedFuture {
					// Idle timeout applies to plain HTTP only; WebSocket connections are
					// long-lived and manage their own liveness.
					if let idleTimeout = idleTimeout {
						try channel.pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: idleTimeout))
						try channel.pipeline.syncOperations.addHandler(IdleTimeoutHandler())
					}
					return HTTPOrWebSocket.http(try HTTPConnectionChannel(wrappingChannelSynchronously: channel))
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
		let responseEncoder = HTTPResponseEncoder()
		let requestDecoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
		var extraHTTPHandlers: [RemovableChannelHandler] = [requestDecoder]
		try sync.addHandler(responseEncoder)
		try sync.addHandler(requestDecoder)
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
	                                             idleTimeout: TimeAmount?) throws -> EventLoopFuture<HTTPOrWebSocket> {
		let resolved = NIOLockedValueBox<(WebSocketHandler, [WebSocketOption])?>(nil)
		let promise = channel.eventLoop.makePromise(of: HTTPOrWebSocket.self)

		let sync = channel.pipeline.syncOperations
		let responseEncoder = HTTPResponseEncoder()
		let requestDecoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
		var extraHTTPHandlers: [RemovableChannelHandler] = [requestDecoder]
		try sync.addHandler(responseEncoder)
		try sync.addHandler(requestDecoder)
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
		let fallbackHandler = PlainHTTPFallbackHandler(idleTimeout: idleTimeout, promise: promise)

		let wsUpgrader = NIOWebSocketServerUpgrader(
			shouldUpgrade: { channel, _ in
				let accept = resolved.withLockedValue { $0 } != nil
				return channel.eventLoop.makeSucceededFuture(accept ? HTTPHeaders() : nil)
			},
			upgradePipelineHandler: { channel, _ in
				// Remove the still-present, never-triggered plain-HTTP tail handler first: it would
				// otherwise sit downstream of the WebSocket frame codec added next and misinterpret
				// the first inbound WebSocketFrame as an HTTPServerRequestPart. Suppressed first so
				// its own handlerRemoved doesn't race a spurious failure against the real success
				// below.
				fallbackHandler.suppressResolution()
				return channel.pipeline.syncOperations.removeHandler(fallbackHandler)
					.flatMap {
						channel.eventLoop.makeCompletedFuture {
							let wsChannel = try WebSocketConnectionChannel(wrappingChannelSynchronously: channel)
							let noop: WebSocketHandler = { _ in }
							let (handler, options) = resolved.withLockedValue { $0 } ?? (noop, [])
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
	fileprivate static func resolveWebSocket(_ request: NIOAsyncHTTPRequest,
	                                         finder: any RouteFinder) async -> (WebSocketHandler, [WebSocketOption])? {
		guard let fnc = finder[request.method, request.path] else { return nil }
		let ctx = RouteContext(request: request, uri: request.path)
		do {
			let (_, output) = try await fnc(ctx, request)
			guard let wsOutput = output as? WebSocketUpgradeHTTPOutput else { return nil }
			return (wsOutput.handler, wsOutput.options)
		} catch {
			return nil
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
	                                  isTLS: Bool) async {
		do {
			if #available(macOS 14, *) {
				try await withThrowingDiscardingTaskGroup { connections in
					try await serverChannel.executeThenClose { inbound in
						for try await upgradeResult in inbound {
							connections.addTask {
								await Server.handleConnection(upgradeResult, finder: finder, isTLS: isTLS)
							}
						}
					}
				}
			} else {
				try await Server.runAcceptLoopBounded(serverChannel, finder: finder, isTLS: isTLS)
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
	                                         isTLS: Bool) async throws {
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
						await Server.handleConnection(upgradeResult, finder: finder, isTLS: isTLS)
					}
					active += 1
				}
			}
		}
	}

	/// Awaits one connection's upgrade outcome and dispatches it to the right driver.
	private static func handleConnection(_ upgradeResult: EventLoopFuture<HTTPOrWebSocket>,
	                                     finder: any RouteFinder,
	                                     isTLS: Bool) async {
		do {
			switch try await upgradeResult.get() {
			case .http(let channel):
				await NIOAsyncHTTPServer.handleConnection(channel, finder: finder, isTLS: isTLS)
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

/// Closes a connection when `IdleStateHandler` reports it idle. Sits directly after the
/// `IdleStateHandler` in the pipeline; constructed on the event loop, never shared.
private final class IdleTimeoutHandler: ChannelInboundHandler {
	typealias InboundIn = NIOAny
	func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
		if event is IdleStateHandler.IdleStateEvent {
			context.close(promise: nil)
		} else {
			context.fireUserInboundEventTriggered(event)
		}
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
/// it adds the idle-timeout handlers (matching `configureUpgrade`'s `notUpgradingCompletionHandler`),
/// wraps the channel, fulfills the promise, forwards the part into the new wrap, and removes itself.
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

	private let idleTimeout: TimeAmount?
	private let promise: EventLoopPromise<HTTPOrWebSocket>
	private var resolved = false

	init(idleTimeout: TimeAmount?, promise: EventLoopPromise<HTTPOrWebSocket>) {
		self.idleTimeout = idleTimeout
		self.promise = promise
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
			if let idleTimeout {
				try context.pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: idleTimeout))
				try context.pipeline.syncOperations.addHandler(IdleTimeoutHandler())
			}
			let httpChannel = try HTTPConnectionChannel(wrappingChannelSynchronously: context.channel)
			promise.succeed(.http(httpChannel))
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
private final class WebSocketUpgradeRouter: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
	typealias InboundIn = HTTPServerRequestPart
	typealias InboundOut = HTTPServerRequestPart

	private enum State { case awaitingHead, resolving, passthrough }
	private var state: State = .awaitingHead
	private var buffered: [HTTPServerRequestPart] = []
	private let finder: any RouteFinder
	private let isTLS: Bool
	private let resolved: NIOLockedValueBox<(WebSocketHandler, [WebSocketOption])?>

	init(finder: any RouteFinder, isTLS: Bool, resolved: NIOLockedValueBox<(WebSocketHandler, [WebSocketOption])?>) {
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
			guard case .head(let head) = part, Self.isWebSocketUpgrade(head) else {
				// Not a WebSocket handshake; this connection is plain HTTP from here on.
				state = .passthrough
				context.fireChannelRead(data)
				return
			}
			state = .resolving
			buffered.append(part)
			resolve(context: context, head: head)
		}
	}

	private func resolve(context: ChannelHandlerContext, head: HTTPRequestHead) {
		let boundContext = NIOLoopBoundBox(context, eventLoop: context.eventLoop)
		let request = NIOAsyncHTTPRequest(head: head, body: [], channel: context.channel, isTLS: isTLS)
		let finder = self.finder
		let resolved = self.resolved
		Task {
			let ws = await Server.resolveWebSocket(request, finder: finder)
			boundContext.eventLoop.execute {
				if let ws = ws { resolved.withLockedValue { $0 = ws } }
				self.flush(context: boundContext.value, stripUpgrade: ws == nil)
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
		context.pipeline.syncOperations.removeHandler(self, promise: nil)
	}

	private static func isWebSocketUpgrade(_ head: HTTPRequestHead) -> Bool {
		head.headers[canonicalForm: "upgrade"].contains { $0.lowercased() == "websocket" }
	}

	private static func removeWebSocketHeaders(_ head: inout HTTPRequestHead) {
		for name in ["Upgrade", "Sec-WebSocket-Key", "Sec-WebSocket-Version",
		             "Sec-WebSocket-Protocol", "Sec-WebSocket-Extensions"] {
			head.headers.remove(name: name)
		}
		// Drop only the "upgrade" token from Connection, preserving any others (e.g. keep-alive).
		let remaining = head.headers[canonicalForm: "connection"].filter { $0.lowercased() != "upgrade" }
		head.headers.remove(name: "Connection")
		for value in remaining { head.headers.add(name: "Connection", value: String(value)) }
	}
}

/// One-time process setup: ignore SIGPIPE and raise the open-file limit. Runs on first server bind.
private let processGlobalInit: Bool = {
	var sa = sigaction()
#if os(Linux)
	sa.__sigaction_handler.sa_handler = SIG_IGN
#else
	sa.__sigaction_u.__sa_handler = SIG_IGN
#endif
	sa.sa_flags = 0
	sigaction(SIGPIPE, &sa, nil)
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
