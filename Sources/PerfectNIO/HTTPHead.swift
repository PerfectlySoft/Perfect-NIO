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
		let status: HTTPResponseStatus?
		if with.status != .ok {
			status = with.status
		} else {
			status = self.status
		}
		let headers = self.headers + with.headers
		return HTTPHead(status: status, headers: headers)
	}
}
