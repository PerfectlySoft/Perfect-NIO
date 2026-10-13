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
import Logging

private let logger = Logger(label: "perfect.nio.fileoutput")

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
	// Open while the body is being read.
	private var handle: FileHandle?
	/// The most read into memory for one body chunk.
	static let chunkSize = 64 * 1024

	public init(localPath inPath: String) throws {
		var localPath = inPath
		let fm = FileManager.default
		var isDirectory: ObjCBool = false
		guard fm.fileExists(atPath: localPath, isDirectory: &isDirectory) else {
			throw ErrorOutput(status: .notFound, description: "The specified file did not exist.")
		}
		// fileExists(atPath:isDirectory:) works on every platform; comparing the .type
		// attribute to a string only worked on Darwin, so on Linux a directory was "served"
		// and reading it trapped inside FileHandle.
		if isDirectory.boolValue {
			localPath = inPath + "/index.html"
			guard fm.fileExists(atPath: localPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
				throw ErrorOutput(status: .notFound, description: "The specified file did not exist.")
			}
		}
		let attr = try fm.attributesOfItem(atPath: localPath)
		guard let fileSize = (attr[.size] as? NSNumber)?.int64Value ?? (attr[.size] as? Int64),
		      let date = attr[.modificationDate] as? Date else {
			throw ErrorOutput(status: .internalServerError, description: "Could not read the file.")
		}
		size = Int(fileSize)
		modDate = Int(date.timeIntervalSince1970)
		path = localPath
		super.init()
	}

	public override func head(request: HTTPRequestInfo) -> HTTPHead? {
		let eTag = getETag()
		let lastModified = Self.httpDate(modDate)
		var headers = [("Accept-Ranges", "bytes"), ("ETag", eTag), ("Last-Modified", lastModified)]
		// If-None-Match (RFC 9110 §13.1.2): a list of tags or "*", compared weakly.
		let ifNoneMatch = request.head.headers[canonicalForm: "if-none-match"].map {
			$0.trimmingCharacters(in: .whitespaces)
		}
		if ifNoneMatch.contains(where: { $0 == "*" || Self.weakTag($0) == Self.weakTag(eTag) }) {
			return HTTPHead(status: .notModified, headers: HTTPHeaders(headers))
		}
		let contentType = MIMEType.forExtension(path.filePathExtension)
		headers.append(("Content-Type", contentType))
		if let rangeRequest = request.head.headers["range"].first,
		   rangeIsCurrent(request.head.headers.first(name: "if-range"), eTag: eTag, lastModified: lastModified),
		   let range = parseRangeHeader(fromHeader: rangeRequest, max: size).first {
			headers.append(("Content-Length", "\(range.count)"))
			headers.append(("Content-Range", "bytes \(range.startIndex)-\(range.endIndex-1)/\(size)"))
			byteRange = range
			return HTTPHead(status: .partialContent, headers: HTTPHeaders(headers))
		}
		headers.append(("Content-Length", "\(size)"))
		byteRange = 0..<size
		return HTTPHead(status: .ok, headers: HTTPHeaders(headers))
	}

	/// If-Range (RFC 9110 §13.1.5): a range is served only if the validator still matches;
	/// otherwise the client's earlier copy is stale and it gets the whole file. An entity tag
	/// must match strongly (a weak tag never does); a date must equal Last-Modified exactly.
	func rangeIsCurrent(_ ifRange: String?, eTag: String, lastModified: String) -> Bool {
		guard let ifRange = ifRange?.trimmingCharacters(in: .whitespaces) else { return true }
		if ifRange.hasPrefix("\"") || ifRange.hasPrefix("W/") {
			return ifRange == eTag
		}
		return ifRange == lastModified
	}

	/// The tag without a weak "W/" prefix, for weak comparison.
	static func weakTag(_ tag: String) -> String {
		tag.hasPrefix("W/") ? String(tag.dropFirst(2)) : tag
	}

	/// An IMF-fixdate (RFC 9110 §5.6.7).
	static func httpDate(_ secondsSince1970: Int) -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(identifier: "GMT")
		formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
		return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(secondsSince1970)))
	}

	public override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
		guard let range = byteRange, !range.isEmpty else {
			closed()
			return nil
		}
		let fh: FileHandle
		if let handle {
			fh = handle
		} else {
			do {
				fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
				try fh.seek(toOffset: UInt64(range.lowerBound))
			} catch {
				// The response goes to the client; the local path stays in the log.
				logger.error("Could not open file", metadata: ["path": "\(path)", "error": "\(error)"])
				throw ErrorOutput(status: .internalServerError, description: "Could not read the file.")
			}
			handle = fh
		}
		// Read the range a chunk at a time, so a large file isn't held in memory at once.
		let data: Data
		do {
			data = try fh.read(upToCount: Swift.min(range.count, Self.chunkSize)) ?? Data()
		} catch {
			logger.error("Could not read file", metadata: ["path": "\(path)", "error": "\(error)"])
			closed()
			throw error
		}
		guard !data.isEmpty else {
			// The file shrank after the head (and its Content-Length) went out; the response is
			// short, so end it with an error rather than as if it were complete.
			closed()
			throw ErrorOutput(status: .internalServerError, description: "Could not read the file.")
		}
		byteRange = (range.lowerBound + data.count)..<range.upperBound
		var buf = allocator.buffer(capacity: data.count)
		buf.writeBytes(data)
		return buf
	}

	public override func closed() {
		try? handle?.close()
		handle = nil
	}

	deinit {
		try? handle?.close()
	}

	/// A strong entity tag, quoted as RFC 9110 §8.8.3 requires (it used to be bare hex).
	func getETag() -> String {
		let eTag = (path + "\(modDate)\(size)").utf8.sha1
		return "\"" + eTag.map { $0.hexString }.joined() + "\""
	}

	/// The satisfiable ranges in a `Range: bytes=…` header (RFC 9110 §14.1.1), in order:
	/// "bytes=0-3, 7-9, 10-". The header is client input: ranges that are malformed, backwards,
	/// suffix ranges ("-5", not supported) or that start at or past `max` are dropped.
	func parseRangeHeader(fromHeader header: String, max: Int) -> [Range<Int>] {
		let initialSplit = header.split(separator: "=", maxSplits: 1)
		guard initialSplit.count == 2 &&
				initialSplit[0].trimmingCharacters(in: .whitespaces).lowercased() == "bytes" else {
			return []
		}
		return initialSplit[1].split(separator: ",").compactMap {
			parseOneRange(fromString: $0.trimmingCharacters(in: .whitespaces), max: max)
		}
	}

	/// "0-3" or "7-". The end is inclusive and clamped to the file; nil for an empty result.
	func parseOneRange(fromString string: String, max: Int) -> Range<Int>? {
		let split = string.split(separator: "-", omittingEmptySubsequences: false)
		guard split.count == 2, let lower = Int(split[0]), lower >= 0, lower < max else { return nil }
		if split[1].isEmpty {
			return lower..<max
		}
		// Compare before adding 1, so an end of Int.max can't overflow.
		guard let lastByte = Int(split[1]), lastByte >= lower else { return nil }
		return lower..<(lastByte >= max - 1 ? max : lastByte + 1)
	}
}
