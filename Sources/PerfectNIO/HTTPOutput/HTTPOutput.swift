//
//  HTTPOutput.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2018-11-19.
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

/// Indicates how the `body` func data, and possibly content-length, should be handled
public enum HTTPOutputResponseHint {
	/// content size is known and all content is available
	/// not chunked. calling `body` will deliver the one available block (or nil)
	case fixed
	/// content size is known but all content is not yet available
	/// e.g. the content might be too large to reasonably fit in memory at once
	/// chunked
	case multi
	/// content size is not known.
	/// stream while `body()` returns data
	/// e.g. compressed `.multi` output
	/// chunked
	case stream
}

/// The response output for the client
open class HTTPOutput {
	/// Indicates how the `body` func data, and possibly content-length, should be handled
	var kind: HTTPOutputResponseHint = .fixed // !FIX! is this utilized?
	public init() {}
	/// Optional HTTP head
	open func head(request: HTTPRequestInfo) -> HTTPHead? {
		return nil
	}
	/// Produce body data
	/// Set nil on last chunk
	/// Call promise.fail upon failure
	open func body(promise: EventLoopPromise<IOData?>, allocator: ByteBufferAllocator) {
		promise.succeed(result: nil)
	}
	/// Called when the request has completed either successfully or with a failure.
	/// Sub-classes can override to take special actions or perform cleanup operations.
	/// Inherited implimenation does nothing.
	open func closed() {
		
	}
}
