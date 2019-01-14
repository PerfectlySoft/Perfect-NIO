//
//  MustacheOutput.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2019-01-14.
//

import Foundation
import PerfectMustache
import NIOHTTP1

public struct MustacheOutput: HTTPOutput {
	public var status: HTTPResponseStatus?
	public var headers: HTTPHeaders?
	public var body: [UInt8]?
	public init(templatePath: String,
				inputs: [String:Any],
				contentType: String,
				status: HTTPResponseStatus? = nil,
				headers: [(String, String)] = []) throws {
		let context = MustacheEvaluationContext(templatePath: templatePath, map: inputs)
		let collector = MustacheEvaluationOutputCollector()
		let result = try context.formulateResponse(withCollector: collector)
		let body = Array(result.utf8)
		self.body = body
		self.headers = HTTPHeaders([
			("Content-Type", contentType),
			("Content-Length", "\(body.count)")
			] + headers)
	}
}
