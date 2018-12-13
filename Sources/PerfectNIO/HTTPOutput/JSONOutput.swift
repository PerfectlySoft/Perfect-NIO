//
//  HTTPOutput.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-11-19.
//

import Foundation
import NIOHTTP1

/// JSON output from an Encodable
public struct JSONOutput<E: Encodable>: HTTPOutput {
	public var status: HTTPResponseStatus?
	public var headers: HTTPHeaders? = HTTPHeaders([("content-type", "application/json")])
	public var body: [UInt8]?
	public init(_ encodable: E, status: HTTPResponseStatus? = nil, headers: [(String, String)] = []) throws {
		self.status = status
		body = Array(try JSONEncoder().encode(encodable))
		headers.forEach { self.headers?.add(name: $0.0, value: $0.1) }
	}
}

/// Convert Encodable to JSON output
public extension Routes where OutType: Encodable {
	func json() -> Routes<InType, HTTPOutput> {
		return map { try JSONOutput($0) }
	}
}
