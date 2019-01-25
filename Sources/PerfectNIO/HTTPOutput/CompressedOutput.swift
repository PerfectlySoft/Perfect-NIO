//
//  CompressedOutput.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2019-01-14.
//
// some of this code taken from NIO HTTPResponseCompressor,
// which didn't itself quite fit how things are operating here
// therefore…
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
import CNIOZlib
import NIO

internal extension String {
	/// Test if this `Collection` starts with the unicode scalars of `needle`.
	///
	/// - note: This will be faster than `String.startsWith` as no unicode normalisations are performed.
	///
	/// - parameters:
	///    - needle: The `Collection` of `Unicode.Scalar`s to match at the beginning of `self`
	/// - returns: If `self` started with the elements contained in `needle`.
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
	
	// We have a Q value.
	let qValue = Float(headerParts[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[1]) ?? 0
	if qValue < 0 || qValue > 1 || qValue.isNaN {
		return 0
	}
	return qValue
}

public enum CompressionPolicy {
	case minContentSize(Int) // smallest content-length which will be compressed
	case testContentType((String) -> Bool)
}

public class CompressedOutput: HTTPOutput {
	fileprivate enum CompressionAlgorithm: String {
		case gzip = "gzip"
		case deflate = "deflate"
	}
	private var stream = z_stream()
	private var algorithm: CompressionAlgorithm? // needed?
	private var sourceContent: HTTPOutput
	private let minCompressLength: Int
	private var done = false
	private var buffer: [UInt8] = []
	init(source: HTTPOutput) {
		sourceContent = source
		minCompressLength = 1024 * 14 // !FIX!
		super.init()
		kind = .stream
	}
	public override func head(request: HTTPRequestInfo) -> HTTPHead? {
		let sourceHead = sourceContent.head(request: request)
		guard let algo = compressionAlgorithm(request.head) else {
			return sourceHead
		}
		guard let contentLengthStr = sourceHead?.headers.first(where: { $0.name.lowercased() == "content-length" })?.value,
			let contentLength = Int(contentLengthStr),
			contentLength > minCompressLength else {
			return sourceHead
		}
		var head: HTTPHead
		if let t = sourceHead {
			head = t
		} else {
			head = HTTPHead(headers: HTTPHeaders())
		}
		algorithm = algo
		initializeEncoder(encoding: algo)
		head.headers.remove(name: "content-length")
		head.headers.add(name: "Content-Encoding", value: algo.rawValue)
		return head
	}
	public override func body(_ masterp: EventLoopPromise<[UInt8]?>) {
		guard let _ = self.algorithm else {
			return sourceContent.body(masterp)
		}
		guard !done else {
			return masterp.succeed(result: nil)
		}
		let newp = masterp.futureResult.eventLoop.newPromise(of: [UInt8]?.self)
		newp.futureResult.whenSuccess {
			bytes in
			if let bytes = bytes {
				self.buffer.append(contentsOf: self.compress(bytes, flush: false))
			} else {
				self.done = true
				self.buffer.append(contentsOf: self.compress([], flush: true))
			}
			if self.buffer.count >= self.minCompressLength || self.done {
				let c = self.buffer
				self.buffer = []
				masterp.succeed(result: c)
			} else {
				self.body(masterp)
			}
		}
		newp.futureResult.whenFailure {
			masterp.fail(error: $0)
		}
		sourceContent.body(newp)
	}
	private func compressionAlgorithm(_ head: HTTPRequestHead) -> CompressionAlgorithm? {
		let acceptHeaders = head.headers.filter { $0.name.lowercased() == "accept-encoding" }.map { $0.value }
		var gzipQValue: Float = -1
		var deflateQValue: Float = -1
		var anyQValue: Float = -1
		for fullHeader in acceptHeaders {
			for acceptHeader in fullHeader.split(separator: ",").map(String.init) {
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
			return gzipQValue > deflateQValue ? .gzip : .deflate
		} else if anyQValue > 0 {
			// Though gzip is usually less well compressed than deflate, it has slightly
			// wider support because it's unabiguous. We therefore default to that unless
			// the client has expressed a preference.
			return .gzip
		}
		return nil
	}
	/// Set up the encoder for compressing data according to a specific
	/// algorithm.
	private func initializeEncoder(encoding: CompressionAlgorithm) {
		// zlib docs say: The application must initialize zalloc, zfree and opaque before calling the init function.
		stream.zalloc = nil
		stream.zfree = nil
		stream.opaque = nil
		
		let windowBits: Int32
		switch encoding {
		case .deflate:
			windowBits = 15
		case .gzip:
			windowBits = 16 + 15
		}
		
		let rc = CNIOZlib_deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY)
		precondition(rc == Z_OK, "Unexpected return from zlib init: \(rc)")
	}
	
	private func deinitializeEncoder() {
		// We deliberately discard the result here because we just want to free up
		// the pending data.
		deflateEnd(&stream)
	}
	private func compress(_ bytes: [UInt8], flush: Bool) -> [UInt8] {
		if bytes.isEmpty && !flush {
			return []
		}
		let needed = Int(deflateBound(&stream, UInt(bytes.count)))
		let dest = UnsafeMutablePointer<UInt8>.allocate(capacity: needed)
		defer {
			dest.deallocate()
		}
		if !bytes.isEmpty {
			stream.next_in = UnsafeMutablePointer(mutating: bytes)
			stream.avail_in = uInt(bytes.count)
		} else {
			stream.next_in = nil
			stream.avail_in = 0
		}
		var out = [UInt8]()
		repeat {
			stream.next_out = dest
			stream.avail_out = uInt(needed)
			let err = deflate(&stream, flush ? Z_FINISH : Z_NO_FLUSH)
			guard err != Z_STREAM_ERROR else {
				break
			}
			let have = uInt(needed) - stream.avail_out
			let b2 = UnsafeRawBufferPointer(start: dest, count: Int(have))
			out.append(contentsOf: b2.map { $0 })
		} while stream.avail_out == 0
		return out
	}
}

/// Compresses eligible output
public extension Routes where OutType: HTTPOutput {
	func compressed() -> Routes<InType, HTTPOutput> {
		return map { CompressedOutput(source: $0) }
	}
}
