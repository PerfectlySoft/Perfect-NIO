//
//  HandlerState.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2018-10-12.
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

import NIOHTTP1
import NIO

final class HandlerState {
	var request: NIOHTTPHandler
	var responseHead = HTTPHead(status: .ok, headers: HTTPHeaders())
	var currentComponent: String? {
		guard range.lowerBound < uri.endIndex else {
			return nil
		}
		return String(uri[range])
	}
	var trailingComponents: String? {
		guard range.lowerBound < uri.endIndex else {
			return nil
		}
		return String(uri[range.lowerBound...])
	}
	let uri: [Character]
	var range: Range<Array<Character>.Index>
	var content: HTTPRequestContentType?
	init(request: NIOHTTPHandler, uri: String) {
		self.request = request
		self.uri = Array(uri)
		let si = self.uri.startIndex
		range = si..<(si+1)
		advanceComponent()
	}
	func readContent() -> EventLoopFuture<HTTPRequestContentType> {
		if let c = content {
			return request.channel!.eventLoop.newSucceededFuture(result: c)
		}
		return request.readContent().map {
			self.content = $0
			return $0
		}
	}
	func advanceComponent() {
		var genRange = range.endIndex
		while genRange < uri.endIndex && uri[genRange] == "/" {
			genRange = uri.index(after: genRange)
		}
		guard genRange < uri.endIndex else {
			range = uri.endIndex..<uri.endIndex
			return
		}
		let lowerBound = genRange
		while genRange < uri.endIndex && uri[genRange] != "/" {
			genRange = uri.index(after: genRange)
		}
		range = lowerBound..<genRange
	}
}
