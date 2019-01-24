//
//  HTTPHead.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2019-01-14.
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
