//
//  ErrorOutput.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2018-11-19.
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

/// Output which can be thrown
public class ErrorOutput: BytesOutput, Error, CustomStringConvertible {
	public let description: String
	/// Construct a ErrorOutput with a simple text message
	public init(status: HTTPResponseStatus, description: String? = nil) {
		self.description = description ?? status.reasonPhrase
		let chars = Array(self.description.utf8)
		let headers = HTTPHeaders([("Content-Type", "text/plain")])
		super.init(head: HTTPHead(status: status, headers: headers), body: chars)
	}
}
