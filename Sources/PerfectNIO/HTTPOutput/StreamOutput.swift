//
//  StreamOutput.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2019-01-16.
//

import Foundation
import NIO

/*
/// An object given to a content streamer
public struct StreamToken {
	let state: HandlerState
	let promise: EventLoopPromise<HTTPOutput>
	/// Push a chunk of bytes to the client.
	/// An error thrown from this call will generally indicate that the client has closed the connection.
	public func push(_ bytes: [UInt8]) throws {
		//		if state.request.writeState == .none {
		//			let head = state.responseHead
		//			state.request.writeHead(output: head)
		//		}
		//		let output = BytesOutput(body: )
		//		state.request.write(output: output)
	}
	/// Complete the response streaming.
	public func complete() {
		//		promise.succeed(result: state.response)
	}
	public func fail(error: Error) {
		//		promise.fail(error: error)
	}
}

public struct StreamOutput<InType>: HTTPOutput {
	public let kind: HTTPOutputResponseKind = .stream
	public let head: HTTPHead? = nil
	let input: InType
	
	public init(input: InType) {
		self.input = input
	}
	
	public func body(_ p: EventLoopPromise<[UInt8]?>) {
		p.succeed(result: nil) // writye me
	}
}

public extension Routes {
	/// Stream bytes to the client. Caller should use the `StreamToken` to send data in chunks.
	/// Caller must call `StreamToken.complete()` when done.
	/// Response data is always sent using chunked encoding.
	func stream(_ call: @escaping (OutType, StreamToken) -> ()) -> Routes<InType, HTTPOutput> {
		return applyFuncs {
			input in
			return input.then {
				box in
				let p: EventLoopPromise<HTTPOutput> = input.eventLoop.newPromise()
				let token = StreamToken(state: box.state, promise: p)
				foreignEventsQueue.async { call(box.value, token) }
				return p.futureResult.map { return RouteValueBox(box.state, $0) }
			}
		}
	}
}
*/

