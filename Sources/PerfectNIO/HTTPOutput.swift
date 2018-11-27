//
//  HTTPOutput.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-11-19.
//

import Foundation
import NIOHTTP1

public protocol HTTPOutput {
	var status: HTTPResponseStatus? { get }
	var headers: HTTPHeaders? { get }
	var body: [UInt8]? { get }
}

public struct HTTPOutputError: HTTPOutput, Error {
	public let status: HTTPResponseStatus?
	public let headers: HTTPHeaders?
	public let body: [UInt8]?
	public init(status: HTTPResponseStatus,
				headers: HTTPHeaders? = nil,
				body: [UInt8]? = nil) {
		self.status = status
		self.headers = headers
		self.body = body
	}
	public init(status: HTTPResponseStatus, description: String) {
		let chars = Array(description.utf8)
		self.status = status
		headers = HTTPHeaders([("content-type", "text/plain"), ("content-length", "\(chars.count)")])
		body = chars
	}
}

public struct JSONOutput<E: Encodable>: HTTPOutput {
	public var status: HTTPResponseStatus?
	public var headers: HTTPHeaders? = HTTPHeaders([("content-type", "application/json")])
	public let body: [UInt8]?
	public init(_ encodable: E, status: HTTPResponseStatus? = nil, headers: [(String, String)] = []) throws {
		self.status = status
		body = Array(try JSONEncoder().encode(encodable))
		headers.forEach { self.headers?.add(name: $0.0, value: $0.1) }
	}
}

public struct TextOutput<C: CustomStringConvertible>: HTTPOutput {
	public var status: HTTPResponseStatus?
	public var headers: HTTPHeaders? = HTTPHeaders([("content-type", "text/plain")])
	public let body: [UInt8]?
	public init(_ c: C, status: HTTPResponseStatus? = nil, headers: [(String, String)] = []) {
		self.status = status
		body = Array("\(c)".utf8)
		headers.forEach { self.headers?.add(name: $0.0, value: $0.1) }
	}
}

public struct BytesOutput: HTTPOutput {
	public var status: HTTPResponseStatus?
	public var headers: HTTPHeaders?
	public let body: [UInt8]?
	public init(status: HTTPResponseStatus? = nil,
				headers: HTTPHeaders? = nil,
				body: [UInt8]? = nil) {
		self.status = status
		self.headers = headers
		self.body = body
	}
}

public extension Routes where OutType: Encodable {
	func json() -> Routes<InType, HTTPOutput> {
		return map { try JSONOutput($0) }
	}
}

public extension Routes where OutType: CustomStringConvertible {
	func text() -> Routes<InType, HTTPOutput> {
		return map { TextOutput($0) }
	}
}

// File output
// Mustache output
// Compression
// Logging

//public extension Routes where OutType: HTTPOutput {
//	func compress() -> Routes<InType, HTTPOutput> {
//		return then { try JSONOutput($0) }
//	}
//}
