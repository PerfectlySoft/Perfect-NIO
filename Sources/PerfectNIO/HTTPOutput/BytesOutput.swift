//
//  HTTPOutput.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-11-19.
//

import Foundation
import NIOHTTP1

/// Raw byte output
public struct BytesOutput: HTTPOutput {
	public let status: HTTPResponseStatus?
	public let headers: HTTPHeaders?
	public let body: [UInt8]?
	public init(status: HTTPResponseStatus? = nil,
				headers: HTTPHeaders? = nil,
				body: [UInt8]? = nil) {
		self.status = status
		self.headers = headers
		self.body = body
	}
}
