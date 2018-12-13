//
//  HTTPOutput.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-11-19.
//

import Foundation
import NIOHTTP1

public struct StaticFileOutput: HTTPOutput {
	public var status: HTTPResponseStatus? = .ok
	public var headers: HTTPHeaders?
	public var body: [UInt8]? {
		return nil // ...
	}
	
	public init(localPath: String, status: HTTPResponseStatus = .ok, headers: HTTPHeaders? = nil) {
		self.status = status
		self.headers = headers ?? HTTPHeaders()
		
	}
}
