//
//  MustacheOutput.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2019-01-14.
//

import Foundation
import PerfectMustache
import NIOHTTP1
import NIO
import NIOHTTP1

public class MustacheOutput: HTTPOutput {
	private let head: HTTPHead?
	private var bodyBytes: [UInt8]?
	public init(templatePath: String,
				inputs: [String:Any],
				contentType: String) throws {
		let context = MustacheEvaluationContext(templatePath: templatePath, map: inputs)
		let collector = MustacheEvaluationOutputCollector()
		let result = try context.formulateResponse(withCollector: collector)
		let body = Array(result.utf8)
		bodyBytes = body
		head = HTTPHead(headers: HTTPHeaders([
			("Content-Type", contentType),
			("Content-Length", "\(body.count)")
			]))
	}
	public override func head(request: HTTPRequestHead) -> HTTPHead? {
		return head
	}
	public override func body(_ p: EventLoopPromise<[UInt8]?>) {
		p.succeed(result: bodyBytes)
		bodyBytes = nil
	}
}