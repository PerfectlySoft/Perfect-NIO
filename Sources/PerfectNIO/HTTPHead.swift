//
//  HTTPHead.swift
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
import NIOHTTP1

func +(lhs: HTTPHeaders, rhs: HTTPHeaders) -> HTTPHeaders {
	return HTTPHeaders(lhs.map {$0} + rhs.map {$0})
}

public struct HTTPHead {
	/// Optional HTTP status
	public var status: HTTPResponseStatus?
	/// HTTP headers
	public var headers: HTTPHeaders
	public init(status: HTTPResponseStatus? = nil, headers: HTTPHeaders) {
		self.status = status
		self.headers = headers
	}
	public func merged(with: HTTPHead?) -> HTTPHead {
		guard let with = with else {
			return self
		}
		// The other head's status wins unless it has none or is plain 200, so a status already
		// set here (such as a route context's 201 from statusCheck) isn't lost to an output that
		// doesn't set one. A nil used to count as "not 200" and replaced it.
		let status: HTTPResponseStatus?
		if let withStatus = with.status, withStatus != .ok {
			status = withStatus
		} else {
			status = self.status ?? with.status
		}
		let headers = self.headers + with.headers
		return HTTPHead(status: status, headers: headers)
	}
}
