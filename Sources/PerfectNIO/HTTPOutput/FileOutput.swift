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
import PerfectMIME
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
			r.append(UInt8(bitPattern: bytes[idx]))
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

public class FileOutput: HTTPOutput {
	let path: String
	let size: Int // !FIX! NIO FileRegions only accept Int in init. should be UInt64
	let modDate: Int
	let file: NIO.FileHandle
	var region: FileRegion?
	var useSendfile = true
	public init(localPath: String) throws {
		let fm = FileManager.default
		guard fm.fileExists(atPath: localPath) else {
			throw ErrorOutput(status: .notFound, description: "The specified file did not exist.")
		}
		let attr = try fm.attributesOfItem(atPath: localPath)
		size = Int(attr[FileAttributeKey.size] as! UInt64) // ...
		modDate = Int((attr[.modificationDate] as! Date).timeIntervalSince1970)
		path = localPath
		file = try .init(path: localPath)
		super.init()
		kind = .fixed
	}
	deinit {
		try? file.close()
	}
	public override func head(request: HTTPRequestInfo) -> HTTPHead? {
		let eTag = getETag()
		var headers = [("Accept-Ranges", "bytes")]
		if let ifNoneMatch = request.head.headers["if-none-match"].first,
			ifNoneMatch == eTag {
			// region is nil. no body
			return HTTPHead(status: HTTPResponseStatus.notModified, headers: HTTPHeaders(headers))
		}
		let contentType = MIMEType.forExtension(path.filePathExtension)
		headers.append(("Content-Type", contentType))
		if let rangeRequest = request.head.headers["range"].first, let range = parseRangeHeader(fromHeader: rangeRequest, max: size).first {
			headers.append(("Content-Length", "\(range.count)"))
			headers.append(("Content-Range", "bytes \(range.startIndex)-\(range.endIndex-1)/\(size)"))
			region = FileRegion(fileHandle: file, readerIndex: range.startIndex, endIndex: range.endIndex)
		} else {
			headers.append(("Content-Length", "\(size)"))
			region = FileRegion(fileHandle: file, readerIndex: 0, endIndex: size)
		}
		return HTTPHead(status: .ok, headers: HTTPHeaders(headers))
	}
	public override func body(promise: EventLoopPromise<IOData?>, allocator: ByteBufferAllocator) {
		if let r = region {
			region = nil
			promise.succeed(result: .fileRegion(r))
		} else {
			promise.succeed(result: nil)
		}
	}
	
	func getETag() -> String {
		let eTagStr = path + "\(modDate)"
		let eTag = eTagStr.utf8.sha1
		let eTagReStr = eTag.map { $0.hexString }.joined(separator: "")
		return eTagReStr
	}
	
	// bytes=0-3/7-9/10-15
	func parseRangeHeader(fromHeader header: String, max: Int) -> [Range<Int>] {
		let initialSplit = header.split(separator: "=")
		guard initialSplit.count == 2 && String(initialSplit[0]) == "bytes" else {
			return [Range<Int>]()
		}
		let ranges = initialSplit[1]
		return ranges.split(separator: "/").compactMap { self.parseOneRange(fromString: String($0), max: max) }
	}
	
	// 0-3
	// 0-
	func parseOneRange(fromString string: String, max: Int) -> Range<Int>? {
		let split = string.split(separator: "-", omittingEmptySubsequences: false).map { String($0) }
		guard split.count == 2 else {
			return nil
		}
		if split[1].isEmpty {
			guard let lower = Int(split[0]),
				lower <= max else {
					return nil
			}
			return Range(uncheckedBounds: (lower, max))
		}
		guard let lower = Int(split[0]),
			let upperRaw = Int(split[1]) else {
				return nil
		}
		let upper = Swift.min(max, upperRaw+1)
		guard lower <= upper else {
			return nil
		}
		return Range(uncheckedBounds: (lower, upper))
	}
}
