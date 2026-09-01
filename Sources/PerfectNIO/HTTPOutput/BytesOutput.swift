//
//  BytesOutput.swift
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

import Foundation
import NIO
import NIOHTTP1

/// Raw byte output.
public class BytesOutput: HTTPOutput, @unchecked Sendable {
	private let storedHead: HTTPHead?
	private var bodyBytes: [UInt8]?

	public init(head: HTTPHead? = nil, body: [UInt8]) {
		let headers = HTTPHeaders([("Content-Length", "\(body.count)")])
		storedHead = HTTPHead(headers: headers).merged(with: head)
		bodyBytes = body
		super.init()
	}

	public override func head(request: HTTPRequestInfo) -> HTTPHead? { storedHead }

	public override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
		guard let bytes = bodyBytes else { return nil }
		bodyBytes = nil
		var buf = allocator.buffer(capacity: bytes.count)
		buf.writeBytes(bytes)
		return buf
	}
}
