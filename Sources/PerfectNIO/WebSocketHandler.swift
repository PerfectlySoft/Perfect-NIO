//
//  WebSocketHandler.swift
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
// Phase 6: async WebSocket. The upgrade itself is performed at the pipeline level by
// NIOTypedWebSocketServerUpgrader (configured in Server.swift) — that is the only model
// compatible with NIOAsyncChannel. The route system decides *whether* to upgrade: a
// `webSocket(...)` route is flagged at registration and produces a `WebSocketUpgradeHTTPOutput`
// carrying the handler; at handshake time the server runs only flagged routes to obtain it.
// Other routes are never run during resolution, so they execute once, as plain HTTP. Once upgraded, the connection is
// an NIOAsyncChannel<WebSocketFrame, WebSocketFrame> driven by `AsyncWebSocket` below.
//

import Foundation
import NIO
import NIOCore
import NIOHTTP1
import NIOWebSocket

/// A message read from or written to a WebSocket.
public enum WebSocketMessage: Sendable {
	case close
	case ping, pong
	case text(String), binary([UInt8])
}

/// Per-endpoint WebSocket behavior. Set on the `webSocket(...)` route.
public enum WebSocketOption: Sendable {
	/// Do not auto-reply to a received `.close`; the handler must reply itself. The handler
	/// still receives the `.close` message and the connection closes once the handler returns.
	case manualClose
	/// Do not auto-reply to a received `.ping` with a `.pong`; the handler must reply itself.
	case manualPing
	/// Seconds without a frame from the client before the server sends it a ping. Default
	/// `defaultPingInterval` (30). 0 or less turns the keepalive off, so a client that goes
	/// silent keeps its connection open until it closes it.
	case pingInterval(Int)
	/// Seconds the client has, after a keepalive ping, to send any frame (its pong counts)
	/// before the connection is closed. Default `defaultResponseTimeout` (30); at least 1.
	case responseTimeout(Int)
	/// The largest message, in bytes, this endpoint accepts. A message is limited to the smaller of
	/// this and `Server.maxWebSocketMessageSize`. A larger one, whether sent in one frame or in
	/// fragments, ends the connection with close code 1009 (message too big), and `readMessage()`
	/// returns `.close`.
	case maxMessageSize(Int)

	/// The default for `pingInterval`: 30 seconds.
	public static let defaultPingInterval = 30
	/// The default for `responseTimeout`: 30 seconds.
	public static let defaultResponseTimeout = 30
}

extension Array where Element == WebSocketOption {
	/// The keepalive interval and timeout these options set, or nil when the keepalive is off.
	var keepAlive: (interval: TimeAmount, timeout: TimeAmount)? {
		var interval = WebSocketOption.defaultPingInterval
		var timeout = WebSocketOption.defaultResponseTimeout
		for option in self {
			switch option {
			case .pingInterval(let seconds): interval = seconds
			case .responseTimeout(let seconds): timeout = seconds
			default: break
			}
		}
		guard interval > 0 else { return nil }
		return (.seconds(Int64(interval)), .seconds(Int64(Swift.max(1, timeout))))
	}

	/// The message size limit for an endpoint with these options on a server whose limit is
	/// `serverLimit`.
	func maxMessageSize(serverLimit: Int) -> Int {
		reduce(serverLimit) { limit, option in
			if case .maxMessageSize(let size) = option { return Swift.min(limit, Swift.max(0, size)) }
			return limit
		}
	}
}

/// An upgraded WebSocket connection. Reads and writes are async; calls must be serialized
/// (drive a single read loop, as in the handler examples).
public protocol WebSocket: Sendable {
	/// The options the endpoint was declared with.
	var options: [WebSocketOption] { get }
	/// Awaits and returns the next message. Control frames (ping/pong/close) are delivered too;
	/// auto-pong / auto-close happen first unless disabled via `options`.
	func readMessage() async throws -> WebSocketMessage
	/// Writes a message to the peer.
	func writeMessage(_ message: WebSocketMessage) async throws
}

/// A handler for an upgraded WebSocket connection. Returns when the connection should close.
public typealias WebSocketHandler = @Sendable (WebSocket) async -> Void

public extension Routes {
	/// Declare this route as a WebSocket endpoint. The callback runs through the normal route
	/// pipeline at handshake time and returns the `WebSocketHandler` that drives the connection.
	func webSocket(protocol proto: String,
	               options: [WebSocketOption] = [],
	               _ callback: @Sendable @escaping (OutType) async throws -> WebSocketHandler) -> Routes<InType, HTTPOutput> {
		applyFuncs { ctx, output in
			let handler = try await callback(output)
			return (ctx, WebSocketUpgradeHTTPOutput(webSocketHandler: handler, options: options, protocol: proto))
		}.markingWebSocket()
	}
}

/// Marker output produced by a `webSocket(...)` route. Carries the handler/options that the
/// pipeline-level upgrader extracts. If a non-upgrade request reaches it (a plain GET to a
/// WebSocket endpoint), it responds 426 Upgrade Required. Only routes declared with
/// `webSocket(...)` upgrade: returning this output from any other route does not.
public final class WebSocketUpgradeHTTPOutput: HTTPOutput, @unchecked Sendable {
	let handler: WebSocketHandler
	let options: [WebSocketOption]
	/// The subprotocol the endpoint speaks, selected in the 101 when the client offers it.
	let subprotocol: String?
	/// Building this output by hand does not make a route a WebSocket endpoint: only routes
	/// declared with `webSocket(...)` upgrade, so a hand-built output just answers 426.
	@available(*, deprecated, message: "Declare the route with webSocket(protocol:options:_:); a hand-built WebSocketUpgradeHTTPOutput no longer upgrades the connection")
	public convenience init(handler: @escaping WebSocketHandler, options: [WebSocketOption]) {
		self.init(webSocketHandler: handler, options: options)
	}
	init(webSocketHandler handler: @escaping WebSocketHandler, options: [WebSocketOption], protocol subprotocol: String? = nil) {
		self.handler = handler
		self.options = options
		self.subprotocol = subprotocol
	}
	public override func head(request: HTTPRequestInfo) -> HTTPHead? {
		HTTPHead(status: .upgradeRequired, headers: HTTPHeaders([
			("Connection", "close"), ("Upgrade", "websocket"), ("Sec-WebSocket-Version", "13"),
		]))
	}
}

/// Runs an upgraded WebSocket connection: wraps the frame channel in an `AsyncWebSocket`,
/// invokes the handler, and closes when the handler returns.
enum WebSocketRunner {
	static func run(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
	                handler: WebSocketHandler,
	                options: [WebSocketOption],
	                maxMessageSize: Int) async {
		do {
			try await channel.executeThenClose { inbound, outbound in
				let ws = AsyncWebSocket(iterator: inbound.makeAsyncIterator(),
				                        outbound: outbound,
				                        options: options,
				                        maxMessageSize: maxMessageSize)
				await handler(ws)
			}
		} catch {
			// Connection-level failure; executeThenClose has closed the channel.
		}
	}
}

/// Drives one upgraded connection over its `NIOAsyncChannel<WebSocketFrame, WebSocketFrame>`.
/// `@unchecked Sendable`: used by a single connection task; reads must not be issued concurrently.
private final class AsyncWebSocket: WebSocket, @unchecked Sendable {
	let options: [WebSocketOption]
	private let manualClose: Bool
	private let manualPing: Bool
	private let maxMessageSize: Int
	/// Set once a message over `maxMessageSize` has closed the connection.
	private var closedTooBig = false
	private var iterator: NIOAsyncChannelInboundStream<WebSocketFrame>.AsyncIterator
	private let outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
	private let allocator = ByteBufferAllocator()
	// Carried across readMessage() calls so interleaved control frames don't lose fragment state.
	private var fragmentOpcode: WebSocketOpcode?
	private var fragmentBytes: [UInt8] = []

	init(iterator: NIOAsyncChannelInboundStream<WebSocketFrame>.AsyncIterator,
	     outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
	     options: [WebSocketOption],
	     maxMessageSize: Int) {
		self.iterator = iterator
		self.outbound = outbound
		self.options = options
		self.maxMessageSize = maxMessageSize
		self.manualClose = options.contains { if case .manualClose = $0 { return true }; return false }
		self.manualPing = options.contains { if case .manualPing = $0 { return true }; return false }
	}

	func readMessage() async throws -> WebSocketMessage {
		if closedTooBig { return .close }
		while let frame = try await iterator.next() {
			switch frame.opcode {
			case .connectionClose:
				if !manualClose { try? await writeRawClose() }
				return .close
			case .ping:
				if !manualPing { try await writePong(frame) }
				return .ping
			case .pong:
				return .pong
			case .text, .binary:
				guard frame.length <= maxMessageSize else { return await closeTooBig() }
				let bytes = unmasked(frame)
				if frame.fin {
					return frame.opcode == .text ? .text(string(bytes)) : .binary(bytes)
				}
				fragmentOpcode = frame.opcode
				fragmentBytes = bytes
			case .continuation:
				guard fragmentBytes.count + frame.length <= maxMessageSize else { return await closeTooBig() }
				fragmentBytes.append(contentsOf: unmasked(frame))
				if frame.fin {
					let opcode = fragmentOpcode ?? .binary
					let bytes = fragmentBytes
					fragmentOpcode = nil
					fragmentBytes = []
					return opcode == .text ? .text(string(bytes)) : .binary(bytes)
				}
			default:
				continue
			}
		}
		// Inbound stream ended — peer is gone.
		return .close
	}

	func writeMessage(_ message: WebSocketMessage) async throws {
		switch message {
		case .text(let text):
			var buf = allocator.buffer(capacity: text.utf8.count)
			buf.writeString(text)
			try await outbound.write(WebSocketFrame(fin: true, opcode: .text, data: buf))
		case .binary(let bytes):
			var buf = allocator.buffer(capacity: bytes.count)
			buf.writeBytes(bytes)
			try await outbound.write(WebSocketFrame(fin: true, opcode: .binary, data: buf))
		case .ping:
			try await outbound.write(WebSocketFrame(fin: true, opcode: .ping, data: allocator.buffer(capacity: 0)))
		case .pong:
			try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: allocator.buffer(capacity: 0)))
		case .close:
			try await writeRawClose()
		}
	}

	// MARK: - Helpers

	private func unmasked(_ frame: WebSocketFrame) -> [UInt8] {
		var data = frame.unmaskedData
		return data.readBytes(length: data.readableBytes) ?? []
	}

	private func string(_ bytes: [UInt8]) -> String {
		String(decoding: bytes, as: UTF8.self)
	}

	private func writePong(_ frame: WebSocketFrame) async throws {
		var payload = frame.unmaskedData
		let buf = payload.readSlice(length: payload.readableBytes) ?? allocator.buffer(capacity: 0)
		try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: buf))
	}

	/// Ends a message over `maxMessageSize`: drops what was gathered, sends close code 1009,
	/// and makes every later read return `.close`.
	private func closeTooBig() async -> WebSocketMessage {
		closedTooBig = true
		fragmentOpcode = nil
		fragmentBytes = []
		var code = allocator.buffer(capacity: 2)
		code.write(webSocketErrorCode: .messageTooLarge)
		try? await outbound.write(WebSocketFrame(fin: true, opcode: .connectionClose, data: code))
		return .close
	}

	private func writeRawClose() async throws {
		try await outbound.write(WebSocketFrame(fin: true, opcode: .connectionClose, data: allocator.buffer(capacity: 0)))
	}
}

/// Installs the keepalive on an upgraded connection, unless its options turn it off.
enum WebSocketKeepAlive {
	static func add(to channel: Channel, options: [WebSocketOption]) throws {
		guard let keepAlive = options.keepAlive else { return }
		try channel.pipeline.syncOperations.addHandler(
			WebSocketKeepAliveHandler(interval: keepAlive.interval, timeout: keepAlive.timeout))
	}
}

/// Closes an upgraded connection whose client has gone silent. After `interval` with no frame
/// from the client it sends a ping; if no frame at all arrives within `timeout` of that ping,
/// it closes the connection. Any frame counts, so a client busy sending messages is never
/// pinged. The pong answering the keepalive's own ping is consumed here, so handlers don't
/// see it.
///
/// Sits between the frame codec and the async channel. `@unchecked Sendable`: only touched on
/// its channel's event loop.
final class WebSocketKeepAliveHandler: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
	typealias InboundIn = WebSocketFrame
	typealias InboundOut = WebSocketFrame
	typealias OutboundIn = WebSocketFrame
	typealias OutboundOut = WebSocketFrame

	/// The keepalive ping's payload, which identifies the pong that answers it.
	static let pingPayload = Array("perfect-nio-keepalive".utf8)

	private let interval: TimeAmount
	private let timeout: TimeAmount
	private var lastRead = NIODeadline.now()
	private var pingSentAt: NIODeadline?
	private var check: RepeatedTask?

	init(interval: TimeAmount, timeout: TimeAmount) {
		self.interval = interval
		self.timeout = timeout
	}

	func handlerAdded(context: ChannelHandlerContext) {
		lastRead = .now()
		let step = TimeAmount.nanoseconds(max(min(interval, timeout).nanoseconds / 4, 1_000_000))
		let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
		check = context.eventLoop.scheduleRepeatedTask(initialDelay: step, delay: step) { [weak self] _ in
			self?.tick(context: bound.value)
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
		let frame = unwrapInboundIn(data)
		if frame.opcode == .pong,
		   frame.unmaskedData.readableBytesView.elementsEqual(Self.pingPayload) {
			pingSentAt = nil
			return
		}
		pingSentAt = nil
		context.fireChannelRead(data)
	}

	private func tick(context: ChannelHandlerContext) {
		let now = NIODeadline.now()
		if let sent = pingSentAt {
			if now - sent >= timeout {
				check?.cancel()
				check = nil
				context.close(promise: nil)
			}
		} else if now - lastRead >= interval {
			pingSentAt = now
			var payload = context.channel.allocator.buffer(capacity: Self.pingPayload.count)
			payload.writeBytes(Self.pingPayload)
			context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .ping, data: payload)), promise: nil)
		}
	}
}
