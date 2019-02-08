//
//  WebSocketHandler.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 2016-01-06.
//  Copyright © 2016 PerfectlySoft. All rights reserved.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2016 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

import CNIOSHA1
import NIO
import NIOHTTP1
import NIOWebSocket

public enum WebSocketMessage {
	case close
	case ping, pong
	case text(String), binary([UInt8])
}

/// Default options will automatically handle ping/pong and close sequence
public enum WebSocketOption {
	/// If manual close is not indicated (the default)
	/// then the socket will automatically reply with a .close message.
	/// If manual close is indicated then the handler must reply to the close itself.
	/// In either case the handler will receive the .close message.
	/// In either case the connection will be closed once the close handshake completes.
	case manualClose
	/// If manual ping is not indicated (the default)
	/// then the socket will automatically reply with a .pong message.
	/// If manual ping is indicated then the handler must reply with a .pong.
	/// In either case the handler will receive the .ping message
	case manualPing
	/// The frequency in seconds that the server should ping the client.
	/// This defaults to 30 seconds.
	/// An interval of zero will disable automatic ping/pong.
	case pingInterval(Int)
	
	// pong response timeout?
	case responseTimeout(Int)
}

public protocol WebSocket {
	var options: [WebSocketOption] { get set }
	func readMessage() -> EventLoopFuture<WebSocketMessage>
	func writeMessage(_ message: WebSocketMessage) -> EventLoopFuture<Void>
}

public typealias WebSocketHandler = (WebSocket) -> ()

public extension Routes {
	func webSocket(protocol: String, _ callback: @escaping (OutType) throws -> WebSocketHandler) -> Routes<InType, HTTPOutput> {
		return applyFuncs {
			return $0.thenThrowing {
				RouteValueBox($0.state, WebSocketUpgradeHTTPOutput(state: $0.state, handler: try callback($0.value)))
			}
		}
	}
}

fileprivate extension HTTPHeaders {
	func nonListHeader(_ name: String) -> String? {
		let fields = self[canonicalForm: name]
		guard fields.count == 1 else {
			return nil
		}
		return fields.first
	}
}

private class WebSocketUpgradeHTTPOutput: HTTPOutput {
	private let magicWebSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	let state: HandlerState
	let handler: WebSocketHandler
	var failed = false
	init(state: HandlerState, handler: @escaping WebSocketHandler) {
		self.state = state
		self.handler = handler
	}
	override func head(request: HTTPRequestInfo) -> HTTPHead? {
		var extraHeaders = HTTPHeaders()
		// The version must be 13.
		guard let key = request.head.headers.nonListHeader("Sec-WebSocket-Key"),
			let version = request.head.headers.nonListHeader("Sec-WebSocket-Version"),
			version == "13" else {
				failed = true
				return HTTPHead(status: .badRequest, headers: extraHeaders)
		}
		let acceptValue: String
		do {
			var hasher = SHA1()
			hasher.update(string: key)
			hasher.update(string: magicWebSocketGUID)
			acceptValue = String(base64Encoding: hasher.finish())
		}
		extraHeaders.replaceOrAdd(name: "Upgrade", value: "websocket")
		extraHeaders.add(name: "Sec-WebSocket-Accept", value: acceptValue)
		extraHeaders.replaceOrAdd(name: "Connection", value: "upgrade")
		return HTTPHead(status: .switchingProtocols, headers: extraHeaders)
	}
	
	override func body(promise: EventLoopPromise<IOData?>, allocator: ByteBufferAllocator) {
		guard !failed, let channel = state.request.channel else {
			return promise.succeed(result: nil)
		}
		state.request.upgraded = true
		channel.pipeline.remove(name: "HTTPResponseEncoder")
		.then {
			_ in
			channel.pipeline.remove(name: "HTTPRequestDecoder")
		}.then {
			_ in
			channel.pipeline.remove(name: "HTTPServerPipelineHandler")
		}.then {
			_ in
			channel.pipeline.remove(name: "HTTPServerProtocolErrorHandler")
		}.then {
			_ in
			channel.pipeline.remove(name: "NIOHTTPHandler")
		}.then {
			_ in
			channel.pipeline.addHandlers([	WebSocketFrameEncoder(),
											WebSocketFrameDecoder(maxFrameSize: 1 << 14, automaticErrorHandling: false),
											WebSocketProtocolErrorHandler(),
											NIOWebSocketHandler(channel: channel, socketHandler: self.handler)],
										 first: false)
//		}.then {
//			channel.setOption(option: ChannelOptions.autoRead, value: false) // !FIX! this made it stop reading altogether. rather have messages be pulled
		}.whenComplete {
			promise.succeed(result: nil)
		}
	}
}

public struct WebSocketError: Error, CustomStringConvertible {
	public let description: String
	init(_ description: String) {
		self.description = description
	}
}

private struct NIOWebSocket: WebSocket {
	let handler: NIOWebSocketHandler // !FIX! does this cause retain cycle?
	var options: [WebSocketOption] {
		get { return handler.options }
		set { handler.options = newValue }
	}
	func readMessage() -> EventLoopFuture<WebSocketMessage> {
		return handler.issueRead()
	}
	func writeMessage(_ message: WebSocketMessage) -> EventLoopFuture<Void> {
		return handler.writeMessage(message)
	}
}

private final class NIOWebSocketHandler: ChannelInboundHandler {
	enum CloseState {
		case open, closed, sentClose, receivedClose
	}
	typealias InboundIn = WebSocketFrame
	typealias OutboundOut = WebSocketFrame
	let channel: Channel
	fileprivate var sentClose = false
	fileprivate var socketHandler: WebSocketHandler
	private var waitingPromise: EventLoopPromise<WebSocketMessage>?
	private var waitingMessages: [WebSocketMessage] = []
	var options: [WebSocketOption] = [] {
		didSet {
			for option in options {
				switch option {
				case .manualClose:
					manualClose = true
				case .manualPing:
					manualPing = true
				case .pingInterval(let time):
					pingInterval = time
				case .responseTimeout(let time):
					responseTimeout = time
				}
			}
		}
	}
	var closeState = CloseState.open
	var manualClose = false
	var manualPing = false
	var pingInterval: Int = 0
	var responseTimeout: Int = 0
	
	init(channel: Channel, socketHandler: @escaping WebSocketHandler) {
		self.channel = channel
		self.socketHandler = socketHandler
	}
	func issueRead() -> EventLoopFuture<WebSocketMessage> {
		if !waitingMessages.isEmpty {
			return channel.eventLoop.newSucceededFuture(result: waitingMessages.removeFirst())
		}
		if let p = waitingPromise {
			return p.futureResult
		}
		let p = channel.eventLoop.newPromise(of: WebSocketMessage.self)
		waitingPromise = p
		return p.futureResult
	}
	func writeMessage(_ message: WebSocketMessage) -> EventLoopFuture<Void> {
		switch message {
		case .close:
			switch closeState {
			case .open:
				closeState = .sentClose
			case .closed:
				return channel.eventLoop.newFailedFuture(error: WebSocketError("Connection not open."))
			case .sentClose:
				return channel.eventLoop.newFailedFuture(error: WebSocketError("Close already sent."))
			case .receivedClose:
				closeState = .closed
			}
			let stupidEmptyBuffer = channel.allocator.buffer(capacity: 0)
			let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: stupidEmptyBuffer)
			let fut = channel.writeAndFlush(wrapOutboundOut(closeFrame))
			if case .closed = closeState {
				return fut.then { self.channel.close(mode: .all) }
			}
			return fut
		case .ping:
			let stupidEmptyBuffer = channel.allocator.buffer(capacity: 0)
			let closeFrame = WebSocketFrame(fin: true, opcode: .ping, data: stupidEmptyBuffer)
			return channel.writeAndFlush(wrapOutboundOut(closeFrame))
		case .pong:
			let stupidEmptyBuffer = channel.allocator.buffer(capacity: 0)
			let closeFrame = WebSocketFrame(fin: true, opcode: .pong, data: stupidEmptyBuffer)
			return channel.writeAndFlush(wrapOutboundOut(closeFrame))
		case .text(let text):
			let bytes = Array(text.utf8)
			var buffer = channel.allocator.buffer(capacity: bytes.count)
			buffer.write(bytes: bytes)
			let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
			return channel.writeAndFlush(wrapOutboundOut(frame))
		case .binary(let bytes):
			var buffer = channel.allocator.buffer(capacity: bytes.count)
			buffer.write(bytes: bytes)
			let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
			return channel.writeAndFlush(wrapOutboundOut(frame))
		}
	}
	public func handlerAdded(ctx: ChannelHandlerContext) {
		socketHandler(NIOWebSocket(handler: self))
	}
	public func handlerRemoved(ctx: ChannelHandlerContext) {
		
	}
	public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
		let frame = unwrapInboundIn(data)
		switch frame.opcode {
		case .connectionClose:
			switch closeState {
			case .open:
				closeState = .receivedClose
				if !manualClose {
					writeMessage(.close).whenComplete {
						self.queueMessage(.close)
					}
				} else {
					queueMessage(.close)
				}
			case .sentClose:
				closeState = .closed
				ctx.close(mode: .all).whenComplete {
					self.queueMessage(.close)
				}
			case .closed, .receivedClose:
				closeOnError(ctx: ctx)
			}
		case .unknownControl, .unknownNonControl:
			closeOnError(ctx: ctx)
		case .ping:
			if !manualPing {
				pong(ctx: ctx, frame: frame)
			}
			queueMessage(.ping)
		case .text:
			var data = frame.unmaskedData
			let text = data.readString(length: data.readableBytes) ?? ""
			queueMessage(.text(text))
		case .binary:
			var data = frame.unmaskedData
			let binary = data.readBytes(length: data.readableBytes) ?? []
			queueMessage(.binary(binary))
		case .continuation:
			()
		case .pong:
			queueMessage(.pong)
		}
	}
	private func queueMessage(_ msg: WebSocketMessage) {
		waitingMessages.append(msg)
		checkWaitingPromise()
	}
	@discardableResult
	private func checkWaitingPromise() -> Bool {
		guard !waitingMessages.isEmpty, let p = waitingPromise else {
			return false
		}
		waitingPromise = nil
		p.succeed(result: waitingMessages.removeFirst())
		return true
	}
	public func channelReadComplete(ctx: ChannelHandlerContext) {
		ctx.flush()
	}
	
	private func receivedClose(ctx: ChannelHandlerContext, frame: WebSocketFrame) {
//		if awaitingClose {
			ctx.close(promise: nil)
//		} else {
//			var data = frame.unmaskedData
//			let closeDataCode = data.readSlice(length: 2) ?? ctx.channel.allocator.buffer(capacity: 0)
//			let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
//			_ = ctx.write(wrapOutboundOut(closeFrame)).map { () in
//				ctx.close(promise: nil)
//			}
//		}
		closeState = .closed
	}
	
	private func pong(ctx: ChannelHandlerContext, frame: WebSocketFrame) {
		var frameData = frame.data
		let maskingKey = frame.maskKey
		if let maskingKey = maskingKey {
			frameData.webSocketUnmask(maskingKey)
		}
		let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
		ctx.write(wrapOutboundOut(responseFrame), promise: nil)
	}
	
	private func closeOnError(ctx: ChannelHandlerContext) {
		var data = ctx.channel.allocator.buffer(capacity: 2)
		data.write(webSocketErrorCode: .protocolError)
		let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
		ctx.write(wrapOutboundOut(frame)).whenComplete {
			ctx.close(mode: .output, promise: nil)
		}
		closeState = .closed
	}
}

//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// The base64 unicode table.
private let base64Table: [UnicodeScalar] = [
	"A", "B", "C", "D", "E", "F", "G", "H",
	"I", "J", "K", "L", "M", "N", "O", "P",
	"Q", "R", "S", "T", "U", "V", "W", "X",
	"Y", "Z", "a", "b", "c", "d", "e", "f",
	"g", "h", "i", "j", "k", "l", "m", "n",
	"o", "p", "q", "r", "s", "t", "u", "v",
	"w", "x", "y", "z", "0", "1", "2", "3",
	"4", "5", "6", "7", "8", "9", "+", "/",
]

private extension String {
	/// Base64 encode an array of UInt8 to a string, without the use of Foundation.
	///
	/// This function performs the world's most naive Base64 encoding: no attempts to use a larger
	/// lookup table or anything intelligent like that, just shifts and masks. This works fine, for
	/// now: the purpose of this encoding is to avoid round-tripping through Data, and the perf gain
	/// from avoiding that is more than enough to outweigh the silliness of this code.
	init(base64Encoding array: Array<UInt8>) {
		// In Base64, 3 bytes become 4 output characters, and we pad to the nearest multiple
		// of four.
		var outputString = String()
		outputString.reserveCapacity(((array.count + 2) / 3) * 4)
		
		var bytes = array.makeIterator()
		while let firstByte = bytes.next() {
			let secondByte = bytes.next()
			let thirdByte = bytes.next()
			outputString.unicodeScalars.append(String.encode(firstByte: firstByte))
			outputString.unicodeScalars.append(String.encode(firstByte: firstByte, secondByte: secondByte))
			outputString.unicodeScalars.append(String.encode(secondByte: secondByte, thirdByte: thirdByte))
			outputString.unicodeScalars.append(String.encode(thirdByte: thirdByte))
		}
		
		self = outputString
	}
	
	private static func encode(firstByte: UInt8) -> UnicodeScalar {
		let index = firstByte >> 2
		return base64Table[Int(index)]
	}
	
	private static func encode(firstByte: UInt8, secondByte: UInt8?) -> UnicodeScalar {
		var index = (firstByte & 0b00000011) << 4
		if let secondByte = secondByte {
			index += (secondByte & 0b11110000) >> 4
		}
		return base64Table[Int(index)]
	}
	
	private static func encode(secondByte: UInt8?, thirdByte: UInt8?) -> UnicodeScalar {
		guard let secondByte = secondByte else {
			// No second byte means we are just emitting padding.
			return "="
		}
		var index = (secondByte & 0b00001111) << 2
		if let thirdByte = thirdByte {
			index += (thirdByte & 0b11000000) >> 6
		}
		return base64Table[Int(index)]
	}
	
	private static func encode(thirdByte: UInt8?) -> UnicodeScalar {
		guard let thirdByte = thirdByte else {
			// No third byte means just padding.
			return "="
		}
		let index = thirdByte & 0b00111111
		return base64Table[Int(index)]
	}
}


private struct SHA1 {
	private var sha1Ctx: SHA1_CTX
	
	/// Create a brand-new hash context.
	init() {
		self.sha1Ctx = SHA1_CTX()
		c_nio_sha1_init(&self.sha1Ctx)
	}
	
	/// Feed the given string into the hash context as a sequence of UTF-8 bytes.
	///
	/// - parameters:
	///     - string: The string that will be UTF-8 encoded and fed into the
	///         hash context.
	mutating func update(string: String) {
		let buffer = Array(string.utf8)
		buffer.withUnsafeBufferPointer {
			self.update($0)
		}
	}
	
	/// Feed the bytes into the hash context.
	///
	/// - parameters:
	///     - bytes: The bytes to feed into the hash context.
	mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
		c_nio_sha1_loop(&self.sha1Ctx, bytes.baseAddress!, bytes.count)
	}
	
	/// Complete the hashing.
	///
	/// - returns: A 20-byte array of bytes.
	mutating func finish() -> [UInt8] {
		var hashResult: [UInt8] = Array(repeating: 0, count: 20)
		hashResult.withUnsafeMutableBufferPointer {
			$0.baseAddress!.withMemoryRebound(to: Int8.self, capacity: 20) {
				c_nio_sha1_result(&self.sha1Ctx, $0)
			}
		}
		return hashResult
	}
}
