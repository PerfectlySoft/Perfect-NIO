//
//  NIOHTTPHandler.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-10-30.
//

import NIO
import NIOHTTP1

/// An object given to a content streamer
public struct StreamToken {
	let state: HandlerState
	let promise: EventLoopPromise<HTTPOutput>
	/// Push a chunk of bytes to the client.
	/// An error thrown from this call will generally indicate that the client has closed the connection.
	public func push(_ bytes: [UInt8]) throws {
		let output: DefaultHTTPOutput
		if state.request.writeState == .none {
			let def = state.response
			output = DefaultHTTPOutput(status: def.status, headers: def.headers, body: bytes)
		} else {
			output = DefaultHTTPOutput(status: nil, headers: HTTPHeaders(), body: bytes)
		}
		state.request.write(output: output)
	}
	/// Complete the response streaming.
	public func complete() {
		promise.succeed(result: state.response)
	}
}

public extension Routes {
	/// Run the call asynchronously on a non-event loop thread.
	/// Caller must succeed or fail the given promise to continue the request.
	func async<NewOut>(_ call: @escaping (OutType, EventLoopPromise<NewOut>) -> ()) -> Routes<InType, NewOut> {
		return applyFuncs {
			input in
			return input.then {
				box in
				let p: EventLoopPromise<NewOut> = input.eventLoop.newPromise()
				foreignEventsQueue.async { call(box.value, p) }
				return p.futureResult.map { return RouteValueBox(box.state, $0) }
			}
		}
	}
	/// Stream bytes to the client. Caller should use the `StreamToken` to send data in chunks.
	/// Caller must call `StreamToken.complete()` when done.
	/// Response data is always sent using chunked encoding.
	func stream(_ call: @escaping (OutType, StreamToken) -> ()) -> Routes<InType, HTTPOutput> {
		return applyFuncs {
			input in
			return input.then {
				box in
				let p: EventLoopPromise<HTTPOutput> = input.eventLoop.newPromise()
				let token = StreamToken(state: box.state, promise: p)
				foreignEventsQueue.async { call(box.value, token) }
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
	
	let finder: RouteFinder
	var head: HTTPRequestHead?
	var channel: Channel?
	var pendingBytes: [ByteBuffer] = []
	var pendingPromise: EventLoopPromise<[ByteBuffer]>?
	var readState = State.none
	var writeState = State.none
	var forceKeepAlive: Bool? = nil
	
	init(finder: RouteFinder) {
		self.finder = finder
	}
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
		let promise: EventLoopPromise<[ByteBuffer]> = channel.eventLoop.newPromise()
		readSomeContent(promise)
		return promise.futureResult
	}
	func readSomeContent(_ promise: EventLoopPromise<[ByteBuffer]>) {
		guard contentConsumed < contentLength else {
			return promise.succeed(result: [])
		}
		let content = consumeContent()
		if !content.isEmpty {
			return promise.succeed(result: content)
		}
		pendingPromise = promise
//		channel?.read()
	}
	// content can only be read once
	func readContent() -> EventLoopFuture<HTTPRequestContentType> {
		if contentLength == 0 || contentConsumed == contentLength {
			return channel!.eventLoop.newSucceededFuture(result: .none)
		}
		let ret: EventLoopFuture<HTTPRequestContentType>
		let ct = contentType ?? "application/octet-stream"
		if ct.hasPrefix("multipart/form-data") {
			let p: EventLoopPromise<HTTPRequestContentType> = channel!.eventLoop.newPromise()
			readContent(multi: MimeReader(ct), p)
			ret = p.futureResult
		} else {
			let p: EventLoopPromise<[UInt8]> = channel!.eventLoop.newPromise()
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
			return promise.succeed(result: .multiPartForm(multi))
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
			return promise.succeed(result: a)
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
				promise.succeed(result: a)
			} else {
				self.readContent(accum: a, promise)
			}
		}
	}
	func channelActive(ctx: ChannelHandlerContext) {
		channel = ctx.channel
//		channel?.read()
	}
	func channelInactive(ctx: ChannelHandlerContext) {
		return
	}
	func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
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
	func runRequest() {
		guard let head = self.head, let fnc = finder[head.method, path] else {
			return flush(output: HTTPOutputError(status: .notFound, description: "No route for URI."))
		}
		let state = HandlerState(request: self, uri: path)
		let f = channel!.eventLoop.newSucceededFuture(result: RouteValueBox(state, self as HTTPRequest))
		let p = try! fnc(f)
		p.whenSuccess {
			self.flush(output: $0.value)
		}
		p.whenFailure {
			error in
			let output: HTTPOutput
			switch error {
			case let error as TerminationType:
				switch error {
				case .error(let e):
					output = e
				case .criteriaFailed:
					output = state.response
				case .internalError:
					output = HTTPOutputError(status: .internalServerError)
				}
			default:
				output = HTTPOutputError(status: .internalServerError, description: "Error caught: \(error)")
			}
			self.flush(output: output)
		}
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
//		if contentLength > 0 {
//			channel?.read()
//		}
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
			p.succeed(result: consumeContent())
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
	
	func writeHead(output: HTTPOutput) {
		guard let head = head else {
			return
		}
		let headers = output.headers ?? HTTPHeaders()
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
	func write(output: HTTPOutput) {
		switch writeState {
		case .none:
			writeState = .head
			writeHead(output: output)
			fallthrough
		case .head, .body:
			if let b = output.body, let channel = self.channel {
				writeState = .body
				var buffer = channel.allocator.buffer(capacity: b.count)
				buffer.write(bytes: b)
				channel.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
			}
		case .end:
			()
		}
	}
	func flush(output: HTTPOutput? = nil) {
		if let o = output {
			if case .none = writeState {
				var headers = o.headers ?? HTTPHeaders()
				headers.replaceOrAdd(name: "content-length", value: "\(o.body?.count ?? 0)")
				let newO = DefaultHTTPOutput(status: o.status, headers: headers, body: o.body)
				write(output: newO)
			} else {
				write(output: o)
			}
		}
		if let channel = self.channel {
			let p: EventLoopPromise<Void> = channel.eventLoop.newPromise()
			let keepAlive = forceKeepAlive ?? head?.isKeepAlive ?? false
			p.futureResult.whenComplete {
				if !keepAlive {
					channel.close(promise: nil)
				}
			}
			reset()
			channel.writeAndFlush(wrapOutboundOut(.end(nil)), promise: p)
//			if keepAlive {
//				channel.read()
//			}
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
	
	func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
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
	
	func channelReadComplete(ctx: ChannelHandlerContext) {
		return
	}
	
	//	func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
	//		if event is IdleStateHandler.IdleStateEvent {
	//			_ = ctx.close()
	//		} else {
	//			ctx.fireUserInboundEventTriggered(event)
	//		}
	//	}
}
