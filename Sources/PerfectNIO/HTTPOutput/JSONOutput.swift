//
//  HTTPOutput.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-11-19.
//

import Foundation
import NIOHTTP1

/// JSON output from an Encodable
public class JSONOutput<E: Encodable>: BytesOutput {
	public init(_ encodable: E, head: HTTPHead? = nil) throws {
		let body = Array(try JSONEncoder().encode(encodable))
		let useHeaders = HTTPHeaders([("content-type", "application/json")])
		super.init(head: HTTPHead(headers: useHeaders).merged(with: head), body: body)
	}
}

/// Convert Encodable to JSON output
public extension Routes where OutType: Encodable {
	func json() -> Routes<InType, HTTPOutput> {
		return map { try JSONOutput($0) }
	}
}
