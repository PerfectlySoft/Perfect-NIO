//
//  HTTPOutput.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-11-19.
//

import Foundation
import NIOHTTP1

/// A bit of output for the client
public protocol HTTPOutput {
	/// Optional HTTP status
	var status: HTTPResponseStatus? { get }
	/// Optional HTTP headers
	var headers: HTTPHeaders? { get }
	/// Optional body data
	var body: [UInt8]? { get }
}

/// Output which can be thrown
public struct HTTPOutputError: HTTPOutput, Error {
	/// HTTP status. This will not be nil, though it is optional to comply with the protocol.
	public let status: HTTPResponseStatus?
	/// Optional HTTP Headers
	public let headers: HTTPHeaders?
	/// Any body data for the response
	public let body: [UInt8]?
	/// Construct a HTTPOutputError
	public init(status: HTTPResponseStatus,
				headers: HTTPHeaders? = nil,
				body: [UInt8]? = nil) {
		self.status = status
		self.headers = headers
		self.body = body
	}
	/// Construct a HTTPOutputError with a simple text message
	public init(status: HTTPResponseStatus, description: String) {
		let chars = Array(description.utf8)
		self.status = status
		headers = HTTPHeaders([("content-type", "text/plain"), ("content-length", "\(chars.count)")])
		body = chars
	}
}
