//
//  CompressedOutput.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2019-01-14.
//
// some of this code taken from NIO HTTPResponseCompressor,
// which didn't itself quite fit how things are operating here
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

import Foundation
import NIOHTTP1
import CZlib
import Logging

private let logger = Logger(label: "perfect.nio.compressedoutput")
import NIO

internal extension String {
	/// Test if this `Collection` starts with the unicode scalars of `needle`.
	///
	/// - note: This will be faster than `String.startsWith` as no unicode normalisations are performed.
	func startsWithSameUnicodeScalars<S: StringProtocol>(string needle: S) -> Bool {
		return self.unicodeScalars.starts(with: needle.unicodeScalars)
	}
}

/// Given a header value, extracts the q value if there is one present. If one is not present,
/// returns the default q value, 1.0.
private func qValueFromHeader(_ text: String) -> Float {
	let headerParts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
	guard headerParts.count > 1 && headerParts[1].count > 0 else {
		return 1
	}
	let qValue = Float(headerParts[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[1]) ?? 0
	if qValue < 0 || qValue > 1 || qValue.isNaN {
		return 0
	}
	return qValue
}

public class CompressedOutput: HTTPOutput, @unchecked Sendable {
	fileprivate enum CompressionAlgorithm: String {
		case gzip = "gzip"
		case deflate = "deflate"
	}
	private var stream = z_stream()
	private var algorithm: CompressionAlgorithm?
	private var sourceContent: HTTPOutput
	private let minCompressLength: Int
	private var done = false
	private let chunkSize = 32 * 1024
	private let noCompressMimes = ["image/", "video/", "audio/"]

	public init(source: HTTPOutput) {
		sourceContent = source
		minCompressLength = 1024 * 14
		super.init()
	}
	deinit {
		deinitializeEncoder()
	}

	public override func head(request: HTTPRequestInfo) -> HTTPHead? {
		guard let algo = compressionAlgorithm(request.head) else {
			return sourceContent.head(request: request)
		}
		let newRequest = HTTPRequestInfo(head: request.head, options: request.options.union(.mayCompress))
		let sourceHead = sourceContent.head(request: newRequest)
		if let contentLengthStr = sourceHead?.headers["content-length"].first,
		   let contentLength = Int(contentLengthStr),
		   contentLength < minCompressLength {
			return sourceHead
		}
		if let contentTypeStr = sourceHead?.headers["content-type"].first,
		   noCompressMimes.first(where: { contentTypeStr.hasPrefix($0) }) != nil {
			return sourceHead
		}
		var head: HTTPHead = sourceHead ?? HTTPHead(headers: HTTPHeaders())
		algorithm = algo
		initializeEncoder(encoding: algo)
		head.headers.remove(name: "content-length")
		head.headers.add(name: "Content-Encoding", value: algo.rawValue)
		return head
	}

	public override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
		// If compression was not chosen (content too small / wrong mime type), pass through.
		guard algorithm != nil else {
			return try await sourceContent.nextChunk(allocator: allocator)
		}
		guard !done else { return nil }

		guard let chunk = try await sourceContent.nextChunk(allocator: allocator) else {
			// Source exhausted — flush the compressor and mark done.
			done = true
			let flushed = compress(nil, allocator: allocator)
			return flushed.readableBytes > 0 ? flushed : nil
		}
		let compressed = compress(chunk, allocator: allocator)
		return compressed.readableBytes > 0 ? compressed : nil
	}

	private func compressionAlgorithm(_ head: HTTPRequestHead) -> CompressionAlgorithm? {
		let acceptHeaders = head.headers["accept-encoding"]
		var gzipQValue: Float = -1
		var deflateQValue: Float = -1
		var anyQValue: Float = -1
		for fullHeader in acceptHeaders {
			for acceptHeader in fullHeader.replacingOccurrences(of: " ", with: "").split(separator: ",").map(String.init) {
				if acceptHeader.startsWithSameUnicodeScalars(string: "gzip") || acceptHeader.startsWithSameUnicodeScalars(string: "x-gzip") {
					gzipQValue = qValueFromHeader(acceptHeader)
				} else if acceptHeader.startsWithSameUnicodeScalars(string: "deflate") {
					deflateQValue = qValueFromHeader(acceptHeader)
				} else if acceptHeader.startsWithSameUnicodeScalars(string: "*") {
					anyQValue = qValueFromHeader(acceptHeader)
				}
			}
		}
		if gzipQValue > 0 || deflateQValue > 0 {
			return gzipQValue >= deflateQValue ? .gzip : .deflate
		} else if anyQValue > 0 {
			return .gzip
		}
		return nil
	}

	private func initializeEncoder(encoding: CompressionAlgorithm) {
		stream.zalloc = nil
		stream.zfree = nil
		stream.opaque = nil
		let windowBits: Int32
		switch encoding {
		case .deflate: windowBits = 15
		case .gzip:    windowBits = 16 + 15
		}
		let rc = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
		precondition(rc == Z_OK, "Unexpected return from zlib init: \(rc)")
	}

	private func deinitializeEncoder() {
		deflateEnd(&stream)
	}

	// Pass nil to flush and finish the zlib stream.
	private func compress(_ bytes: ByteBuffer?, allocator: ByteBufferAllocator) -> ByteBuffer {
		defer {
			stream.next_out = nil
			stream.avail_out = 0
			stream.next_in = nil
			stream.avail_in = 0
		}
		let readable = bytes?.readableBytes ?? 0
		let needed = Int(deflateBound(&stream, UInt(readable))) + (readable == 0 ? 4096 : 0)
		var dest = allocator.buffer(capacity: needed)

		if var bytes = bytes {
			dest.writeWithUnsafeMutableBytes(minimumWritableBytes: needed) { outputPtr in
				let typedOutputPtr = UnsafeMutableBufferPointer(
					start: outputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), count: needed)
				stream.next_out = typedOutputPtr.baseAddress
				stream.avail_out = UInt32(needed)
				bytes.readWithUnsafeMutableReadableBytes { dataPtr in
					let typedDataPtr = UnsafeMutableBufferPointer(
						start: dataPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), count: readable)
					stream.next_in = typedDataPtr.baseAddress
					stream.avail_in = UInt32(readable)
					let rc = deflate(&stream, Z_NO_FLUSH)
					if rc != Z_OK || stream.avail_in != 0 {
						logger.debug("deflate returned rc \(rc)")
					}
					return readable - Int(stream.avail_in)
				}
				return needed - Int(stream.avail_out)
			}
		} else {
			stream.next_in = nil
			stream.avail_in = 0
			var rc = Z_OK
			while rc != Z_ERRNO {
				dest.writeWithUnsafeMutableBytes(minimumWritableBytes: needed) { outputPtr in
					let typedOutputPtr = UnsafeMutableBufferPointer(
						start: outputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), count: needed)
					stream.next_out = typedOutputPtr.baseAddress
					stream.avail_out = UInt32(needed)
					rc = deflate(&stream, Z_FINISH)
					return needed - Int(stream.avail_out)
				}
				if rc == Z_STREAM_END { break }
				dest.reserveCapacity(dest.capacity + needed)
			}
		}
		return dest
	}
}

/// Compresses eligible output.
public extension Routes where OutType: HTTPOutput {
	func compressed() -> Routes<InType, HTTPOutput> {
		return map { CompressedOutput(source: $0) }
	}
}
