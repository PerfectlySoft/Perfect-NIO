//
//  HTTPOutput.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-11-19.
//

import Foundation
import NIO
import NIOHTTP1

// write me. all of me
public class FileOutput: HTTPOutput {
	public init(localPath: String) {
		super.init()
		self.kind = .fixed
	}
	public override func head(request: HTTPRequestHead) -> HTTPHead? {
		return nil
	}
	public override func body(_ p: EventLoopPromise<[UInt8]?>) {
		p.succeed(result: nil)
	}
}
