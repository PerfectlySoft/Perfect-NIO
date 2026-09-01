//
//  NIOAsyncHTTPHandler.swift
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
// Phase 4: replaces the legacy `NIOHTTPHandler: ChannelInboundHandler` with an
// NIOAsyncChannel-based serve loop. Each connection is driven by a structured
// `async` task; the full request (head + body) is assembled before dispatch and
// the response body is pulled directly via `HTTPOutput.nextChunk(allocator:)`.
//

import NIO
import NIOCore
import NIOHTTP1
import Foundation

/// The per-request object handed to the route pipeline.
///
/// In the NIOAsyncChannel model the entire request is buffered before dispatch,
/// so `readContent()` / `readSomeContent()` serve from an in-memory byte buffer
/// rather than pulling from the channel mid-handling.
///
/// `@unchecked Sendable`: created and consumed within a single connection task.
/// `uriVariables` is mutated only during route resolution (before the body runs),
/// and `contentConsumed` is touched only by the owning task.
final class NIOAsyncHTTPRequest: HTTPRequest, @unchecked Sendable {
	let requestHead: HTTPRequestHead
	private let bodyBytes: [UInt8]
	private let channelRef: Channel?
	let isTLS: Bool

	var method: HTTPMethod { requestHead.method }
	var uri: String { requestHead.uri }
	var headers: HTTPHeaders { requestHead.headers }
	var uriVariables: [String: String] = [:]
	let path: String
	let searchArgs: QueryDecoder?
	let contentType: String?
	let contentLength: Int
	var contentRead: Int { bodyBytes.count }
	private(set) var contentConsumed: Int = 0
	var channel: Channel? { channelRef }
	var localAddress: SocketAddress? { channelRef?.localAddress }
	var remoteAddress: SocketAddress? { channelRef?.remoteAddress }
	var isKeepAlive: Bool { requestHead.isKeepAlive }

	init(head: HTTPRequestHead, body: [UInt8], channel: Channel?, isTLS: Bool) {
		self.requestHead = head
		self.bodyBytes = body
		self.channelRef = channel
		self.isTLS = isTLS
		let (path, args) = head.uri.splitQuery
		self.path = path
		self.searchArgs = args.map { QueryDecoder(Array($0.utf8)) }
		self.contentType = head.headers["content-type"].first
		self.contentLength = body.count
	}

	func readSomeContent() async throws -> [ByteBuffer] {
		guard contentConsumed < bodyBytes.count else { return [] }
		var buf = ByteBufferAllocator().buffer(capacity: bodyBytes.count)
		buf.writeBytes(bodyBytes)
		contentConsumed = bodyBytes.count
		return [buf]
	}

	func readContent() async throws -> HTTPRequestContentType {
		guard !bodyBytes.isEmpty else { return .none }
		contentConsumed = bodyBytes.count
		let ct = contentType ?? "application/octet-stream"
		if ct.hasPrefix("multipart/form-data") {
			let multi = MimeReader(ct)
			multi.addToBuffer(bytes: bodyBytes)
			return .multiPartForm(multi)
		} else if ct.hasPrefix("application/x-www-form-urlencoded") {
			return .urlForm(QueryDecoder(bodyBytes))
		} else {
			return .other(bodyBytes)
		}
	}
}

/// Drives a single accepted connection: assemble request → dispatch route → write response,
/// looping for keep-alive until the client closes or a non-keep-alive response is sent.
enum NIOAsyncHTTPServer {
	typealias Inbound = HTTPServerRequestPart
	typealias Outbound = HTTPServerResponsePart

	static func handleConnection(
		_ asyncChannel: NIOAsyncChannel<Inbound, Outbound>,
		finder: any RouteFinder,
		isTLS: Bool
	) async {
		do {
			try await asyncChannel.executeThenClose { inbound, outbound in
				var iterator = inbound.makeAsyncIterator()
				while let request = try await assembleRequest(
					iterator: &iterator,
					channel: asyncChannel.channel,
					isTLS: isTLS
				) {
					let (head, output) = await dispatch(request: request, finder: finder, isTLS: isTLS)
					try await writeResponse(head: head, output: output, request: request, outbound: outbound)
					output.closed()
					// Keep-alive behavior confirmed (Phase 7):
					//   1. HTTPRequestHead.isKeepAlive correctly returns false for HTTP/1.0 and for
					//      HTTP/1.1 with `Connection: close`; the break here closes after the response.
					//   2. Client disconnect mid-keep-alive: iterator.next() returns nil (or throws),
					//      causing assembleRequest to return nil and exit the loop cleanly — equivalent
					//      to the legacy handler's explicit inputClosed ChannelEvent path.
					//   3. Idle timeout: handled by IdleStateHandler in Server.serve() (Phase 5).
					//      Future hardening: per-request receive deadline for slow-trickle slowloris
					//      (read-idle timer resets on each byte; a whole-request deadline does not).
					if !request.isKeepAlive { break }
				}
			}
		} catch {
			// Connection-level failure (client reset, write error, protocol error).
			// executeThenClose has already closed the underlying channel.
		}
	}

	/// Reads inbound parts until a complete request (`.head` … `.end`) is framed.
	/// Returns nil when the inbound stream ends (client closed) or the request was truncated.
	private static func assembleRequest(
		iterator: inout NIOAsyncChannelInboundStream<Inbound>.AsyncIterator,
		channel: Channel,
		isTLS: Bool
	) async throws -> NIOAsyncHTTPRequest? {
		guard let firstPart = try await iterator.next() else { return nil }
		guard case .head(let head) = firstPart else {
			// Body or end with no preceding head — malformed; abandon the connection.
			return nil
		}
		var body: [UInt8] = []
		while let part = try await iterator.next() {
			switch part {
			case .head:
				// A second head before .end is a framing error.
				return nil
			case .body(let buffer):
				body.append(contentsOf: buffer.readableBytesView)
			case .end:
				return NIOAsyncHTTPRequest(head: head, body: body, channel: channel, isTLS: isTLS)
			}
		}
		// Stream ended before .end — truncated request.
		return nil
	}

	/// Resolves the route and runs the async pipeline, mapping thrown errors to outputs.
	private static func dispatch(
		request: NIOAsyncHTTPRequest,
		finder: any RouteFinder,
		isTLS: Bool
	) async -> (HTTPHead, HTTPOutput) {
		let requestInfo = HTTPRequestInfo(head: request.requestHead, options: isTLS ? .isTLS : [])
		guard let fnc = finder[request.method, request.path] else {
			let error = ErrorOutput(status: .notFound, description: "No route for URI.")
			let head = HTTPHead(headers: HTTPHeaders()).merged(with: error.head(request: requestInfo))
			return (head, error)
		}
		let ctx = RouteContext(request: request, uri: request.path)
		do {
			let (finalCtx, output) = try await fnc(ctx, request)
			let head = finalCtx.responseHead.merged(with: output.head(request: requestInfo))
			return (head, output)
		} catch {
			let output: HTTPOutput
			switch error {
			case let err as TerminationType:
				switch err {
				case .error(let e):
					output = e
				case .criteriaFailed(let status):
					output = BytesOutput(head: HTTPHead(status: status, headers: ctx.responseHeaders), body: [])
				case .internalError:
					output = ErrorOutput(status: .internalServerError, description: "Internal server error.")
				}
			case let err as ErrorOutput:
				output = err
			default:
				output = ErrorOutput(status: .internalServerError, description: "Internal server error: \(error)")
			}
			let head = ctx.responseHead.merged(with: output.head(request: requestInfo))
			return (head, output)
		}
	}

	/// Writes the response head, pulls the body via `nextChunk()`, and terminates with `.end`.
	private static func writeResponse(
		head: HTTPHead,
		output: HTTPOutput,
		request: NIOAsyncHTTPRequest,
		outbound: NIOAsyncChannelOutboundWriter<Outbound>
	) async throws {
		let version = request.requestHead.version
		var responseHead = HTTPResponseHead(version: version,
		                                    status: head.status ?? .ok,
		                                    headers: head.headers)
		if !request.headers.contains(name: "keep-alive") && !request.headers.contains(name: "close") {
			switch (request.isKeepAlive, version.major, version.minor) {
			case (true, 1, 0):
				responseHead.headers.add(name: "Connection", value: "keep-alive")
			case (false, 1, let n) where n >= 1:
				responseHead.headers.add(name: "Connection", value: "close")
			default:
				()
			}
		}
		try await outbound.write(.head(responseHead))
		let allocator = ByteBufferAllocator()
		while let chunk = try await output.nextChunk(allocator: allocator) {
			if chunk.readableBytes > 0 {
				try await outbound.write(.body(.byteBuffer(chunk)))
			}
		}
		try await outbound.write(.end(nil))
	}
}
