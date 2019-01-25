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
import NIO
import NIOHTTP1
import PerfectLib
import CNIOSHA1

extension String.UTF8View {
	var sha1: [UInt8] {
		let bytes = UnsafeMutablePointer<Int8>.allocate(capacity:  Int(SHA1_RESULTLEN))
		defer { bytes.deallocate() }
		let src = Array<UInt8>(self)
		var ctx = SHA1_CTX()
		c_nio_sha1_init(&ctx)
		c_nio_sha1_loop(&ctx, src, src.count)
		c_nio_sha1_result(&ctx, bytes)
		var r = [UInt8]()
		for idx in 0..<Int(SHA1_RESULTLEN) {
			r.append(UInt8(bytes[idx]))
		}
		return r
	}
}

extension UInt8 {
	// same as String(self, radix: 16)
	// but outputs two characters. i.e. 0 padded
	var hexString: String {
		let s = String(self, radix: 16)
		if s.count == 1 {
			return "0" + s
		}
		return s
	}
}

// write me. all of me
public class FileOutput: HTTPOutput {
	let file: File
	public init(localPath: String) throws {
		file = File(localPath)
		guard file.exists else {
			throw ErrorOutput(status: .notFound, description: "The specified file did not exist.")
		}
		super.init()
		kind = .fixed
	}
	public override func head(request: HTTPRequestInfo) -> HTTPHead? {
		let eTag = getETag()
		let size = file.size
		let contentType = MimeType.forExtension(file.path.filePathExtension)
		
		
		
		return nil
	}
	public override func body(_ p: EventLoopPromise<[UInt8]?>) {
		p.succeed(result: nil)
	}
	
	func getETag() -> String {
		let eTagStr = file.path + "\(file.modificationTime)"
		let eTag = eTagStr.utf8.sha1
		let eTagReStr = eTag.map { $0.hexString }.joined(separator: "")
		return eTagReStr
	}
}
