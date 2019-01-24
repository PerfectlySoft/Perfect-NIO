//
//  ErrorOutput.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-11-19.
//

import Foundation
import NIOHTTP1

/// Output which can be thrown
public class ErrorOutput: BytesOutput, Error {
	/// Construct a ErrorOutput with a simple text message
	public init(status: HTTPResponseStatus, description: String? = nil) {
		let description = description ?? status.reasonPhrase
		let chars = Array(description.utf8)
		let headers = HTTPHeaders([("content-type", "text/plain"), ("content-length", "\(chars.count)")])
		super.init(head: HTTPHead(status: status, headers: headers), body: chars)
	}
}
