//
//  HTTPOutput.swift
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
import NIOHTTP1
import NIO

/// The response output for the client.
open class HTTPOutput: @unchecked Sendable {
	public init() {}

	/// Optional HTTP head for this output.
	open func head(request: HTTPRequestInfo) -> HTTPHead? { nil }

	/// Produce the next chunk of body data. Return nil when the body is complete.
	/// The connection serve loop pulls the body by calling this repeatedly until it returns nil.
	open func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? { nil }

	/// Called when the response has been fully written or on error.
	/// Override to perform cleanup (e.g. closing file handles).
	open func closed() {}
}
