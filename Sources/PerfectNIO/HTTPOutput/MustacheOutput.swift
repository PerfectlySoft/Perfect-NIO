//
//  MustacheOutput.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2019-01-14.
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
import PerfectMustache
import NIOHTTP1
import NIO
import NIOHTTP1

public class MustacheOutput: HTTPOutput {
	private let head: HTTPHead?
	private var bodyBytes: [UInt8]?
	public init(templatePath: String,
				inputs: [String:Any],
				contentType: String) throws {
		let context = MustacheEvaluationContext(templatePath: templatePath, map: inputs)
		let collector = MustacheEvaluationOutputCollector()
		let result = try context.formulateResponse(withCollector: collector)
		let body = Array(result.utf8)
		bodyBytes = body
		head = HTTPHead(headers: HTTPHeaders([
			("Content-Type", contentType),
			("Content-Length", "\(body.count)")
			]))
	}
	public override func head(request: HTTPRequestInfo) -> HTTPHead? {
		return head
	}
	public override func body(promise: EventLoopPromise<IOData?>, allocator: ByteBufferAllocator) {
		if let b = bodyBytes {
			bodyBytes = nil
			var buf = allocator.buffer(capacity: b.count)
			buf.write(bytes: b)
			promise.succeed(result: IOData.byteBuffer(buf))
		} else {
			promise.succeed(result: nil)
		}
	}
}
