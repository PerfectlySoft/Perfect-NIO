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
// `webSocket(...)` route produces a `WebSocketUpgradeHTTPOutput` carrying the handler, and
// Server's `shouldUpgrade` runs the route to discover it. Once upgraded, the connection is
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
	/// Reserved: desired server→client ping frequency in seconds. Not yet active.
	case pingInterval(Int)
	/// Reserved: pong response timeout in seconds. Not yet active.
	case responseTimeout(Int)
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
			return (ctx, WebSocketUpgradeHTTPOutput(handler: handler, options: options))
		}
	}
}

/// Marker output produced by a `webSocket(...)` route. Carries the handler/options that the
/// pipeline-level upgrader extracts. If a non-upgrade request reaches it (a plain GET to a
/// WebSocket endpoint), it responds 426 Upgrade Required.
public final class WebSocketUpgradeHTTPOutput: HTTPOutput, @unchecked Sendable {
	let handler: WebSocketHandler
	let options: [WebSocketOption]
	public init(handler: @escaping WebSocketHandler, options: [WebSocketOption]) {
		self.handler = handler
		self.options = options
	}
	public override func head(request: HTTPRequestInfo) -> HTTPHead? {
		HTTPHead(status: .upgradeRequired, headers: HTTPHeaders([("Connection", "close")]))
	}
}

/// Runs an upgraded WebSocket connection: wraps the frame channel in an `AsyncWebSocket`,
/// invokes the handler, and closes when the handler returns.
enum WebSocketRunner {
	static func run(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
	                handler: WebSocketHandler,
	                options: [WebSocketOption]) async {
		do {
			try await channel.executeThenClose { inbound, outbound in
				let ws = AsyncWebSocket(iterator: inbound.makeAsyncIterator(),
				                        outbound: outbound,
				                        options: options)
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
	private var iterator: NIOAsyncChannelInboundStream<WebSocketFrame>.AsyncIterator
	private let outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
	private let allocator = ByteBufferAllocator()
	// Carried across readMessage() calls so interleaved control frames don't lose fragment state.
	private var fragmentOpcode: WebSocketOpcode?
	private var fragmentBytes: [UInt8] = []

	init(iterator: NIOAsyncChannelInboundStream<WebSocketFrame>.AsyncIterator,
	     outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>,
	     options: [WebSocketOption]) {
		self.iterator = iterator
		self.outbound = outbound
		self.options = options
		self.manualClose = options.contains { if case .manualClose = $0 { return true }; return false }
		self.manualPing = options.contains { if case .manualPing = $0 { return true }; return false }
	}

	func readMessage() async throws -> WebSocketMessage {
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
				let bytes = unmasked(frame)
				if frame.fin {
					return frame.opcode == .text ? .text(string(bytes)) : .binary(bytes)
				}
				fragmentOpcode = frame.opcode
				fragmentBytes = bytes
			case .continuation:
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

	private func writeRawClose() async throws {
		try await outbound.write(WebSocketFrame(fin: true, opcode: .connectionClose, data: allocator.buffer(capacity: 0)))
	}
}
