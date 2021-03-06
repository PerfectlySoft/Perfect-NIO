//
//  NIOHTTPHandler.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2018-10-30.
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

import NIO
import NIOHTTP1

public extension Routes {
	/// Run the call asynchronously on a non-event loop thread.
	/// Caller must succeed or fail the given promise to continue the request.
	func async<NewOut>(_ call: @escaping (OutType, EventLoopPromise<NewOut>) -> ()) -> Routes<InType, NewOut> {
		return applyFuncs {
			input in
			return input.flatMap {
				box in
				let p: EventLoopPromise<NewOut> = input.eventLoop.makePromise()
				foreignEventsQueue.async { call(box.value, p) }
				return p.futureResult.map { return RouteValueBox(box.state, $0) }
			}
		}
	}
}

final class NIOHTTPHandler: ChannelInboundHandler, HTTPRequest {
	public typealias InboundIn = HTTPServerRequestPart
	public typealias OutboundOut = HTTPServerResponsePart
	enum State {
		case none, head, body, end
	}
	var method: HTTPMethod { return head?.method ?? .GET }
	var uri: String { return head?.uri ?? "" }
	var headers: HTTPHeaders { return head?.headers ?? .init() }
	var uriVariables: [String:String] = [:]
	var path: String = ""
	var searchArgs: QueryDecoder?
	var contentType: String? = nil
	var contentLength = 0
	var contentRead = 0
	var contentConsumed = 0 {
		didSet {
			assert(contentConsumed <= contentRead && contentConsumed <= contentLength)
		}
	}
	var localAddress: SocketAddress? { return channel?.localAddress }
	var remoteAddress: SocketAddress? { return channel?.remoteAddress }
	
	let finder: RouteFinder
	var head: HTTPRequestHead?
	var channel: Channel?
	var pendingBytes: [ByteBuffer] = []
	var pendingPromise: EventLoopPromise<[ByteBuffer]>?
	var readState = State.none
	var writeState = State.none
	var forceKeepAlive: Bool? = nil
	var upgraded = false
	let isTLS: Bool
	init(finder: RouteFinder, isTLS: Bool) {
		self.finder = finder
		self.isTLS = isTLS
	}
	deinit {
//		print("~NIOHTTPHandler")
	}
	
	func runRequest() {
		guard let requestHead = self.head else {
			return
		}
		let requestInfo = HTTPRequestInfo(head: requestHead, options: isTLS ? .isTLS : [])
		guard let fnc = finder[requestHead.method, path] else {
			
			// !FIX! routes need pre-request error handlers, 404
			let error = ErrorOutput(status: .notFound, description: "No route for URI.")
			let head = HTTPHead(headers: HTTPHeaders()).merged(with: error.head(request: requestInfo))
			return write(head: head, body: error)
		}
		let state = HandlerState(request: self, uri: path)
		let f = channel!.eventLoop.makeSucceededFuture(RouteValueBox(state, self as HTTPRequest))
		let p = try! fnc(f)
		p.whenSuccess {
			let body = $0.value
			let head = state.responseHead.merged(with: body.head(request: requestInfo))
			self.write(head: head, body: body)
		}
		p.whenFailure {
			error in
			var body: HTTPOutput
			switch error {
			case let error as TerminationType:
				switch error {
				case .error(let e):
					body = e
				case .criteriaFailed:
					body = BytesOutput(head: state.responseHead, body: [])
				case .internalError:
					body = ErrorOutput(status: .internalServerError, description: "Internal server error.")
				}
			case let error as ErrorOutput:
				body = error
			default:
				body = ErrorOutput(status: .internalServerError, description: "Internal server error: \(error)")
			}
			let head = state.responseHead.merged(with: body.head(request: requestInfo))
			self.write(head: head, body: body)
		}
	}
	func channelActive(context ctx: ChannelHandlerContext) {
		channel = ctx.channel
//		print("channelActive")
	}
	func channelInactive(context ctx: ChannelHandlerContext) {
//		print("~channelInactive")
	}
	func channelRead(context ctx: ChannelHandlerContext, data: NIOAny) {
		let reqPart = unwrapInboundIn(data)
		switch reqPart {
		case .head(let head):
			http(head: head, ctx: ctx)
		case .body(let body):
			http(body: body, ctx: ctx)
		case .end(let headers):
			http(end: headers, ctx: ctx)
		}
	}
	func errorCaught(context ctx: ChannelHandlerContext, error: Error) {
		// we don't have any recognized errors to be caught here
		ctx.close(promise: nil)
	}
	func http(head: HTTPRequestHead, ctx: ChannelHandlerContext) {
		assert(contentLength == 0)
		readState = .head
		self.head = head
		let (path, args) = head.uri.splitQuery
		self.path = path
		if let args = args {
			searchArgs = QueryDecoder(Array(args.utf8))
		}
		contentType = head.headers["content-type"].first
		contentLength = Int(head.headers["content-length"].first ?? "0") ?? 0
	}
	func http(body: ByteBuffer, ctx: ChannelHandlerContext) {
		let onlyHead = readState == .head
		
		readState = .body
		let readable = body.readableBytes
		if contentRead + readable > contentLength {
			// should this close the invalid request?
			// or does NIO take care of this case?
			let diff = contentLength - contentRead
			if diff > 0, let s = body.getSlice(at: 0, length: diff) {
				pendingBytes.append(s)
			}
			contentRead = contentLength
		} else {
			contentRead += readable
			pendingBytes.append(body)
		}
		if contentRead == contentLength {
			readState = .end
		}
		if let p = pendingPromise {
			pendingPromise = nil
			p.succeed(consumeContent())
		}
		if onlyHead {
			runRequest()
		}
	}
	func http(end: HTTPHeaders?, ctx: ChannelHandlerContext) {
		if case .head = readState {
			runRequest()
		}
	}
	
	func reset() {
		// !FIX! this. it's prone to break when future mutable properties are added
		writeState = .none
		readState = .none
		head = nil
		contentLength = 0
		contentConsumed = 0
		contentRead = 0
		forceKeepAlive = nil
		
		uriVariables = [:]
		path = ""
		searchArgs = nil
		contentType = nil
	}
	
	func userInboundEventTriggered(context ctx: ChannelHandlerContext, event: Any) {
		switch event {
		case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
			// The remote peer half-closed the channel. At this time, any
			// outstanding response will now get the channel closed, and
			// if we are idle or waiting for a request body to finish we
			// will close the channel immediately.
			switch readState {
			case .none, .body:
				ctx.close(promise: nil)
			case .end, .head:
				forceKeepAlive = false
			}
		default:
			ctx.fireUserInboundEventTriggered(event)
		}
	}
	
	func channelReadComplete(context ctx: ChannelHandlerContext) {
		return
	}
}

// reading
extension NIOHTTPHandler {
	func consumeContent() -> [ByteBuffer] {
		let cpy = pendingBytes
		pendingBytes = []
		let sum = cpy.reduce(0) { $0 + $1.readableBytes }
		contentConsumed += sum
		return cpy
	}
	func readSomeContent() -> EventLoopFuture<[ByteBuffer]> {
		precondition(nil != self.channel)
		let channel = self.channel!
		let promise: EventLoopPromise<[ByteBuffer]> = channel.eventLoop.makePromise()
		readSomeContent(promise)
		return promise.futureResult
	}
	func readSomeContent(_ promise: EventLoopPromise<[ByteBuffer]>) {
		guard contentConsumed < contentLength else {
			return promise.succeed([])
		}
		let content = consumeContent()
		if !content.isEmpty {
			return promise.succeed(content)
		}
		pendingPromise = promise
	}
	// content can only be read once
	func readContent() -> EventLoopFuture<HTTPRequestContentType> {
		if contentLength == 0 || contentConsumed == contentLength {
			return channel!.eventLoop.makeSucceededFuture(.none)
		}
		let ret: EventLoopFuture<HTTPRequestContentType>
		let ct = contentType ?? "application/octet-stream"
		if ct.hasPrefix("multipart/form-data") {
			let p: EventLoopPromise<HTTPRequestContentType> = channel!.eventLoop.makePromise()
			readContent(multi: MimeReader(ct), p)
			ret = p.futureResult
		} else {
			let p: EventLoopPromise<[UInt8]> = channel!.eventLoop.makePromise()
			readContent(p)
			if ct.hasPrefix("application/x-www-form-urlencoded") {
				ret = p.futureResult.map {
					.urlForm(QueryDecoder($0))
				}
			} else {
				ret = p.futureResult.map { .other($0) }
			}
		}
		return ret
	}
	
	func readContent(multi: MimeReader, _ promise: EventLoopPromise<HTTPRequestContentType>) {
		if contentConsumed < contentRead {
			consumeContent().forEach {
				multi.addToBuffer(bytes: $0.getBytes(at: 0, length: $0.readableBytes) ?? [])
			}
		}
		if contentConsumed == contentLength {
			return promise.succeed(.multiPartForm(multi))
		}
		readSomeContent().whenSuccess {
			buffers in
			buffers.forEach {
				multi.addToBuffer(bytes: $0.getBytes(at: 0, length: $0.readableBytes) ?? [])
			}
			self.readContent(multi: multi, promise)
		}
	}
	
	func readContent(_ promise: EventLoopPromise<[UInt8]>) {
		// fast track
		if contentRead == contentLength {
			var a: [UInt8] = []
			consumeContent().forEach {
				a.append(contentsOf: $0.getBytes(at: 0, length: $0.readableBytes) ?? [])
			}
			return promise.succeed(a)
		}
		readContent(accum: [], promise)
	}
	
	func readContent(accum: [UInt8], _ promise: EventLoopPromise<[UInt8]>) {
		readSomeContent().whenSuccess {
			buffers in
			var a: [UInt8]
			if buffers.count == 1 && accum.isEmpty {
				a = buffers.first!.getBytes(at: 0, length: buffers.first!.readableBytes) ?? []
			} else {
				a = accum
				buffers.forEach {
					a.append(contentsOf: $0.getBytes(at: 0, length: $0.readableBytes) ?? [])
				}
			}
			if self.contentConsumed == self.contentLength {
				promise.succeed(a)
			} else {
				self.readContent(accum: a, promise)
			}
		}
	}
}

// writing
extension NIOHTTPHandler {
	func write(head: HTTPHead, body: HTTPOutput) {
		writeHead(head)
		writeBody(body)
	}
	private func writeHead(_ output: HTTPHead) {
		guard let head = head else {
			return // …
		}
		writeState = .head
		let headers = output.headers
		var h = HTTPResponseHead(version: head.version,
								 status: output.status ?? .ok,
								 headers: headers)
		if !self.headers.contains(name: "keep-alive") && !self.headers.contains(name: "close") {
			switch (head.isKeepAlive, head.version.major, head.version.minor) {
			case (true, 1, 0):
				// HTTP/1.0 and the request has 'Connection: keep-alive', we should mirror that
				h.headers.add(name: "Connection", value: "keep-alive")
			case (false, 1, let n) where n >= 1:
				// HTTP/1.1 (or treated as such) and the request has 'Connection: close', we should mirror that
				h.headers.add(name: "Connection", value: "close")
			default:
				()
			}
		}
		channel?.write(wrapOutboundOut(.head(h)), promise: nil)
	}
	private func writeBody(_ body: HTTPOutput) {
		guard let channel = self.channel,
			writeState != .end else {
				return
		}
		let promiseBytes = channel.eventLoop.makePromise(of: IOData?.self)
		promiseBytes.futureResult.whenSuccess {
			let writeDonePromise: EventLoopPromise<Void> = channel.eventLoop.makePromise()
			if let bytes = $0 {
				writeDonePromise.futureResult.whenSuccess {
					_ = channel.eventLoop.submit {
						self.writeBody(body)
					}
				}
				if bytes.readableBytes > 0 {
					channel.writeAndFlush(self.wrapOutboundOut(.body(bytes)), promise: writeDonePromise)
				} else {
					writeDonePromise.succeed(())
				}
			} else {
				let keepAlive = self.forceKeepAlive ?? self.head?.isKeepAlive ?? false
				self.reset()
				if !self.upgraded {
					body.closed()
					writeDonePromise.futureResult.whenComplete {
						_ in
						if !keepAlive {
							channel.close(promise: nil)
						}
					}
					channel.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: writeDonePromise)
				} else {
					channel.flush()
				}				
			}
			writeDonePromise.futureResult.whenFailure {
				error in
				channel.close(promise: nil)
				body.closed()
			}
		}
		promiseBytes.futureResult.whenFailure {
			error in
			channel.close(promise: nil)
			body.closed()
		}
		body.body(promise: promiseBytes, allocator: channel.allocator)
	}
	
	//	func userInboundEventTriggered(context ctx: ChannelHandlerContext, event: Any) {
	//		if event is IdleStateHandler.IdleStateEvent {
	//			_ = ctx.close()
	//		} else {
	//			ctx.fireUserInboundEventTriggered(event)
	//		}
	//	}
}
