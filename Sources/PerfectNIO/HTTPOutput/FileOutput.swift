//
//  FileOutput.swift
//  PerfectNIO
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
import Crypto
import NIO
import NIOHTTP1

extension String.UTF8View {
	var sha1: [UInt8] {
		Array(Insecure.SHA1.hash(data: Data(self)))
	}
}

extension UInt8 {
	var hexString: String {
		let s = String(self, radix: 16)
		return s.count == 1 ? "0" + s : s
	}
}

public class FileOutput: HTTPOutput, @unchecked Sendable {
	let path: String
	let size: Int
	let modDate: Int
	// Set during head(request:) to the byte range that should be served.
	private var byteRange: Range<Int>?

	public init(localPath inPath: String) throws {
		var localPath = inPath
		let fm = FileManager.default
		guard fm.fileExists(atPath: localPath) else {
			throw ErrorOutput(status: .notFound, description: "The specified file did not exist.")
		}
		var attr = try fm.attributesOfItem(atPath: localPath)
		if attr[.type] as? String == "NSFileTypeDirectory" {
			localPath = inPath + "/index.html"
			guard fm.fileExists(atPath: localPath) else {
				throw ErrorOutput(status: .notFound, description: "The specified file did not exist.")
			}
			attr = try fm.attributesOfItem(atPath: localPath)
		}
		size = Int(attr[FileAttributeKey.size] as! UInt64)
		modDate = Int((attr[.modificationDate] as! Date).timeIntervalSince1970)
		path = localPath
		super.init()
	}

	public override func head(request: HTTPRequestInfo) -> HTTPHead? {
		let eTag = getETag()
		var headers = [("Accept-Ranges", "bytes")]
		if let ifNoneMatch = request.head.headers["if-none-match"].first, ifNoneMatch == eTag {
			// ETag match — 304, no body.
			return HTTPHead(status: .notModified, headers: HTTPHeaders(headers))
		}
		let contentType = MIMEType.forExtension(path.filePathExtension)
		headers.append(("Content-Type", contentType))
		headers.append(("ETag", eTag))
		if let rangeRequest = request.head.headers["range"].first,
		   let range = parseRangeHeader(fromHeader: rangeRequest, max: size).first {
			headers.append(("Content-Length", "\(range.count)"))
			headers.append(("Content-Range", "bytes \(range.startIndex)-\(range.endIndex-1)/\(size)"))
			byteRange = range
		} else {
			headers.append(("Content-Length", "\(size)"))
			byteRange = 0..<size
		}
		return HTTPHead(status: .ok, headers: HTTPHeaders(headers))
	}

	public override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
		guard let range = byteRange else { return nil }
		byteRange = nil
		guard !range.isEmpty else { return nil }
		guard let fh = FileHandle(forReadingAtPath: path) else {
			throw ErrorOutput(status: .internalServerError, description: "Could not open file: \(path)")
		}
		defer { fh.closeFile() }
		fh.seek(toFileOffset: UInt64(range.lowerBound))
		let data = fh.readData(ofLength: range.upperBound - range.lowerBound)
		guard !data.isEmpty else { return nil }
		var buf = allocator.buffer(capacity: data.count)
		buf.writeBytes(data)
		return buf
	}

	func getETag() -> String {
		let eTag = (path + "\(modDate)").utf8.sha1
		return eTag.map { $0.hexString }.joined()
	}

	// bytes=0-3/7-9/10-15
	func parseRangeHeader(fromHeader header: String, max: Int) -> [Range<Int>] {
		let initialSplit = header.split(separator: "=")
		guard initialSplit.count == 2 && String(initialSplit[0]) == "bytes" else {
			return []
		}
		return initialSplit[1].split(separator: "/").compactMap {
			parseOneRange(fromString: String($0), max: max)
		}
	}

	// "0-3" or "0-"
	func parseOneRange(fromString string: String, max: Int) -> Range<Int>? {
		let split = string.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
		guard split.count == 2 else { return nil }
		if split[1].isEmpty {
			guard let lower = Int(split[0]), lower <= max else { return nil }
			return lower..<max
		}
		guard let lower = Int(split[0]), let upperRaw = Int(split[1]) else { return nil }
		let upper = Swift.min(max, upperRaw + 1)
		guard lower <= upper else { return nil }
		return lower..<upper
	}
}
