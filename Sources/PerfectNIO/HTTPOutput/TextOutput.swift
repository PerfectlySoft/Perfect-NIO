//
//  HTTPOutput.swift
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

/// Plain text output from a CustomStringConvertible
public class TextOutput<C: CustomStringConvertible>: BytesOutput {
	public init(_ c: C, status: HTTPResponseStatus? = nil, headers: [(String, String)] = []) {
		let body = Array("\(c)".utf8)
		let useHeaders = HTTPHeaders([("content-type", "text/plain")] + headers)
		super.init(head: HTTPHead(status: status, headers: useHeaders), body: body)
	}
}

/// Converts CustomStringConvertible to plain text output
public extension Routes where OutType: CustomStringConvertible {
	func text() -> Routes<InType, HTTPOutput> {
		return map { TextOutput($0) }
	}
}
