//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// SNIPeekHandler reads the raw TLS ClientHello, extracts the Server Name
// Indication (SNI) extension, asks TLSContextManager for the right NIOSSLContext,
// then inserts NIOSSLServerHandler into the pipeline and replays buffered bytes.
//
// Pipeline before first byte:
//   network → [SNIPeekHandler] → [HTTP codec handlers...]
//
// After SNI is resolved:
//   network → [SNIPeekHandler] → [NIOSSLServerHandler] → [HTTP codec handlers...]
//
// After self-removal (all future bytes go directly to NIOSSLServerHandler):
//   network → [NIOSSLServerHandler] → [HTTP codec handlers...]
//
// @unchecked Sendable: all state is accessed exclusively on the channel's
// event loop (channelRead, the eventLoop.execute callback). No sharing.

import NIO
import NIOCore
import NIOSSL

final class SNIPeekHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
	typealias InboundIn  = ByteBuffer
	typealias InboundOut = ByteBuffer

	private enum State { case buffering, resolving, passthrough }
	enum SNIResult {
		case incomplete          // not enough bytes yet — wait for more
		case absent              // full ClientHello has no SNI extension
		case found(String)       // extracted hostname
	}

	private var state: State = .buffering
	private var accumulated: ByteBuffer?
	private let manager: TLSContextManager

	init(manager: TLSContextManager) {
		self.manager = manager
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		switch state {
		case .passthrough:
			context.fireChannelRead(data)
		case .resolving:
			if accumulated == nil {
				accumulated = Self.unwrapInboundIn(data)
			} else {
				var buf = Self.unwrapInboundIn(data)
				accumulated!.writeBuffer(&buf)
			}
		case .buffering:
			var buf = Self.unwrapInboundIn(data)
			if accumulated == nil {
				accumulated = buf
			} else {
				accumulated!.writeBuffer(&buf)
			}
			switch Self.extractSNI(from: accumulated!) {
			case .incomplete:
				break // need more bytes — wait for next channelRead
			case .absent:
				state = .resolving
				resolve(hostname: nil, context: context)
			case .found(let hostname):
				state = .resolving
				resolve(hostname: hostname, context: context)
			}
		}
	}

	private func resolve(hostname: String?, context: ChannelHandlerContext) {
		let loopBound = NIOLoopBoundBox(context, eventLoop: context.eventLoop)
		let manager = self.manager
		Task {
			let sslCtx = await manager.context(for: hostname)
			loopBound.eventLoop.execute {
				self.install(sslCtx: sslCtx, context: loopBound.value)
			}
		}
	}

	private func install(sslCtx: NIOSSLContext?, context: ChannelHandlerContext) {
		guard let sslCtx else {
			context.close(promise: nil)
			return
		}
		let sslHandler = NIOSSLServerHandler(context: sslCtx)
		// NIOLoopBound wraps context (non-Sendable) safely for the @Sendable whenComplete closure.
		// whenComplete fires on the event loop, so .value access is always valid.
		let loopBoundCtx = NIOLoopBound(context, eventLoop: context.eventLoop)
		// Insert NIOSSLServerHandler after us — it sits between us and the HTTP codec.
		// fireChannelRead from our context goes forward to NIOSSLServerHandler. ✅
		context.pipeline.addHandler(sslHandler, position: .after(self)).whenComplete { [weak self] _ in
			guard let self else { return }
			self.state = .passthrough
			let ctx = loopBoundCtx.value
			if let buf = self.accumulated {
				ctx.fireChannelRead(Self.wrapInboundOut(buf))
				ctx.fireChannelReadComplete()
			}
			ctx.pipeline.removeHandler(self, promise: nil)
		}
	}

	// MARK: - TLS ClientHello SNI parser

	/// Parses the SNI hostname from a TLS ClientHello record (RFC 5246 + RFC 6066).
	/// Returns .incomplete if more bytes are needed, .absent if the ClientHello
	/// contains no SNI extension, or .found(hostname) on success.
	static func extractSNI(from buf: ByteBuffer) -> SNIResult {
		var b = buf
		// Minimum to read the full TLS record header + handshake header + fixed ClientHello fields
		// = 5 (record hdr) + 4 (hs hdr) + 2 (version) + 32 (random) = 43 bytes
		guard b.readableBytes >= 43 else { return .incomplete }

		// TLS record header
		guard let contentType: UInt8 = b.readInteger(),
		      contentType == 0x16 else { return .absent } // not a TLS handshake record
		b.moveReaderIndex(forwardBy: 2) // legacy version, ignored
		guard let recordLen: UInt16 = b.readInteger() else { return .incomplete }
		guard b.readableBytes >= Int(recordLen) else { return .incomplete } // need the full record

		// Handshake header
		guard let hsType: UInt8 = b.readInteger(),
		      hsType == 0x01 else { return .absent } // not a ClientHello
		// 24-bit handshake body length
		guard let lenHigh: UInt8 = b.readInteger(),
		      let lenLow: UInt16 = b.readInteger() else { return .incomplete }
		let _ = Int(lenHigh) << 16 | Int(lenLow) // unused — recordLen already guarantees the data

		// ClientHello fixed fields
		guard b.readableBytes >= 34 else { return .incomplete }
		b.moveReaderIndex(forwardBy: 2)  // client_version
		b.moveReaderIndex(forwardBy: 32) // random

		// session_id
		guard let sidLen: UInt8 = b.readInteger() else { return .incomplete }
		guard b.readableBytes >= Int(sidLen) else { return .incomplete }
		b.moveReaderIndex(forwardBy: Int(sidLen))

		// cipher_suites
		guard let csLen: UInt16 = b.readInteger() else { return .incomplete }
		guard b.readableBytes >= Int(csLen) else { return .incomplete }
		b.moveReaderIndex(forwardBy: Int(csLen))

		// compression_methods
		guard let cmLen: UInt8 = b.readInteger() else { return .incomplete }
		guard b.readableBytes >= Int(cmLen) else { return .incomplete }
		b.moveReaderIndex(forwardBy: Int(cmLen))

		// Extensions block (optional — absent in very old TLS 1.0 handshakes)
		guard b.readableBytes >= 2 else { return .absent }
		guard let extTotalLen: UInt16 = b.readInteger() else { return .incomplete }
		guard b.readableBytes >= Int(extTotalLen) else { return .incomplete }

		// Walk extensions looking for type 0x0000 (SNI)
		var remaining = Int(extTotalLen)
		while remaining >= 4 {
			guard let extType: UInt16 = b.readInteger(),
			      let extLen: UInt16 = b.readInteger() else { return .incomplete }
			remaining -= 4

			if extType == 0x0000 { // server_name extension
				// server_name_list_length (uint16) + name_type (uint8) + name_length (uint16)
				guard b.readableBytes >= 5 else { return .incomplete }
				b.moveReaderIndex(forwardBy: 2) // list length
				b.moveReaderIndex(forwardBy: 1) // name_type (0x00 = host_name)
				guard let nameLen: UInt16 = b.readInteger() else { return .incomplete }
				guard let nameBytes = b.readBytes(length: Int(nameLen)) else { return .incomplete }
				let hostname = String(bytes: nameBytes, encoding: .ascii) ?? ""
				return .found(hostname)
			} else {
				guard b.readableBytes >= Int(extLen) else { return .incomplete }
				b.moveReaderIndex(forwardBy: Int(extLen))
				remaining -= Int(extLen)
			}
		}
		return .absent // walked all extensions, no SNI found
	}
}
