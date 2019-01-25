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
import NIO
import NIOHTTP1

/// Raw byte output
public class BytesOutput: HTTPOutput {
	private let head: HTTPHead?
	private var bodyBytes: [UInt8]?
	public init(head: HTTPHead? = nil,
				body: [UInt8]) {
		let headers = HTTPHeaders([("content-length", "\(body.count)")])
		self.head = HTTPHead(headers: headers).merged(with: head)
		bodyBytes = body
	}
	public override func head(request: HTTPRequestHead) -> HTTPHead? {
		return head
	}
	public override func body(_ p: EventLoopPromise<[UInt8]?>) {
		let b = bodyBytes
		bodyBytes = nil
		p.succeed(result: b)
	}
}
