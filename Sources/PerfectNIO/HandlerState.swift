//
//  HandlerState.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-10-12.
//

import NIOHTTP1
import NIO

class DefaultHTTPOutput: HTTPOutput {
	var status: HTTPResponseStatus? = .ok
	var headers: HTTPHeaders? = nil
	var body: [UInt8]? = nil
	init(status s: HTTPResponseStatus? = .ok,
		 headers h: HTTPHeaders? = nil,
		 body b: [UInt8]? = nil) {
		status = s
		headers = h
		body = b
	}
	func addHeader(name: String, value: String) {
		if nil == headers {
			headers = HTTPHeaders()
		}
		headers?.add(name: name, value: value)
	}
}

final class HandlerState {
	var request: NIOHTTPHandler
	var response = DefaultHTTPOutput()
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
