//
//  HTTPOutput.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-11-19.
//

import Foundation
import NIOHTTP1

/// Plain text output from a CustomStringConvertible
public struct TextOutput<C: CustomStringConvertible>: HTTPOutput {
	public var status: HTTPResponseStatus?
	public var headers: HTTPHeaders? = HTTPHeaders([("content-type", "text/plain")])
	public var body: [UInt8]?
	public init(_ c: C, status: HTTPResponseStatus? = nil, headers: [(String, String)] = []) {
		self.status = status
		body = Array("\(c)".utf8)
		headers.forEach { self.headers?.add(name: $0.0, value: $0.1) }
	}
}

/// Converts CustomStringConvertible to plain text output
public extension Routes where OutType: CustomStringConvertible {
	func text() -> Routes<InType, HTTPOutput> {
		return map { TextOutput($0) }
	}
}
