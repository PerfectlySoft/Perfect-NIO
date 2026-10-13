//
//  MalformedInputTests.swift
//  PerfectNIOSmokeTests
//
//  Client-controlled input that used to trap (crashing the whole server process) or
//  mis-handle a response. Each test feeds the parser the value a client could send.
//

import Testing
import Foundation
import NIOCore
import NIOHTTP1
@testable import PerfectNIO

private func requestInfo(_ headers: [(String, String)]) -> HTTPRequestInfo {
	HTTPRequestInfo(head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/",
	                                      headers: HTTPHeaders(headers)),
	                options: [])
}

/// Pulls every chunk from `output`.
private func drain(_ output: HTTPOutput) async throws -> [UInt8] {
	var bytes: [UInt8] = []
	while let chunk = try await output.nextChunk(allocator: ByteBufferAllocator()) {
		bytes += chunk.readableBytesView
	}
	return bytes
}

/// Streams `count` chunks of `chunk` with no Content-Length, like a hand-written HTTPOutput.
private final class ChunkedSource: HTTPOutput, @unchecked Sendable {
	let chunk: [UInt8]
	var remaining: Int
	init(chunk: [UInt8], count: Int) {
		self.chunk = chunk
		self.remaining = count
	}
	override func head(request: HTTPRequestInfo) -> HTTPHead? {
		HTTPHead(headers: HTTPHeaders([("Content-Type", "text/plain")]))
	}
	override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
		guard remaining > 0 else { return nil }
		remaining -= 1
		return allocator.buffer(bytes: chunk)
	}
}

@Suite("Malformed input")
struct MalformedInputTests {

	// MARK: Accept-Encoding

	@Test("A q-less or malformed Accept-Encoding parameter doesn't trap",
	      arguments: ["gzip;q", "gzip;foo", "gzip; level", "deflate;q", "*;x", "gzip;q=", "gzip;;"])
	func acceptEncodingParameterWithoutValue(_ value: String) {
		let output = CompressedOutput(source: BytesOutput(body: Array(repeating: 65, count: 20_000)))
		_ = output.head(request: requestInfo([("Accept-Encoding", value)]))
	}

	@Test func acceptEncodingQValues() {
		func encoding(_ value: String) -> String? {
			let output = CompressedOutput(source: BytesOutput(body: Array(repeating: 65, count: 20_000)))
			return output.head(request: requestInfo([("Accept-Encoding", value)]))?
				.headers.first(name: "content-encoding")
		}
		#expect(encoding("gzip") == "gzip")
		#expect(encoding("gzip;q=0") == nil)
		#expect(encoding("gzip;q=0.5, deflate;q=0.8") == "deflate")
		// A parameter other than q leaves the default q of 1.
		#expect(encoding("gzip;level=9") == "gzip")
		#expect(encoding("deflate;foo;q=0.3") == "deflate")
		#expect(encoding("identity") == nil)
	}

	@Test func compressedStreamIsNotCutShortByAChunkThatCompressesToNothing() async throws {
		// zlib buffers small, repetitive input without emitting anything; such a chunk used to
		// end the response (nextChunk returned nil), dropping the rest and the gzip trailer.
		let chunk = Array(String(repeating: "perfect ", count: 32).utf8)
		let source = ChunkedSource(chunk: chunk, count: 200)
		let output = CompressedOutput(source: source)
		let head = output.head(request: requestInfo([("Accept-Encoding", "gzip")]))
		#expect(head?.headers.first(name: "content-encoding") == "gzip")
		let gzip = try await drain(output)
		#expect(source.remaining == 0, "the source wasn't read to the end")
		// The gzip trailer ends with ISIZE, the uncompressed length mod 2^32, little-endian.
		try #require(gzip.count >= 18)
		let isize = gzip.suffix(4).reversed().reduce(0) { $0 << 8 | Int($1) }
		#expect(isize == chunk.count * 200)
	}

	// MARK: multipart/form-data

	@Test("A multipart Content-Type whose boundary parameter has no value doesn't trap",
	      arguments: ["multipart/form-data; boundary", "multipart/form-data;boundary", "multipart/form-data; boundary="])
	func boundaryWithoutValue(_ contentType: String) {
		#expect(throws: ErrorOutput.self) {
			try MimeReader.parse(contentType: contentType, body: Array("--x\r\n\r\n--x--\r\n".utf8))
		}
	}

	@Test func boundaryParameterIsParsedPerRFC2046() throws {
		for contentType in ["multipart/form-data; boundary=\"abc\"",
		                    "multipart/form-data; boundary=abc; charset=utf-8",
		                    "multipart/form-data; charset=utf-8; BOUNDARY=abc"] {
			let body = Array("--abc\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--abc--\r\n".utf8)
			let reader = try MimeReader.parse(contentType: contentType, body: body)
			#expect(reader.bodySpecs.map(\.fieldName) == ["f"], "\(contentType)")
			#expect(reader.bodySpecs.map(\.fieldValue) == ["v"], "\(contentType)")
		}
	}

	@Test func dispositionParametersAreMatchedByWholeName() throws {
		// "filename=" contains "name="; a filename listed first used to become the field name.
		let body = Array(("--abc\r\nContent-Disposition: form-data; filename=\"x;y.txt\"; name=\"f\"\r\n" +
			"Content-Type: text/plain\r\n\r\nv\r\n--abc--\r\n").utf8)
		let reader = try MimeReader.parse(contentType: "multipart/form-data; boundary=abc", body: body)
		#expect(reader.bodySpecs.map(\.fieldName) == ["f"])
		#expect(reader.bodySpecs.map(\.fileName) == ["x;y.txt"])
		#expect(reader.bodySpecs.map(\.contentType) == ["text/plain"])
	}

	@Test("A part header parameter with nothing after \"=\" doesn't trap",
	      arguments: ["form-data; name=", "form-data; name=\"f\"; filename=", "form-data; name=\""])
	func dispositionParameterWithoutValue(_ disposition: String) {
		let body = Array("--abc\r\nContent-Disposition: \(disposition)\r\n\r\nv\r\n--abc--\r\n".utf8)
		_ = try? MimeReader.parse(contentType: "multipart/form-data; boundary=abc", body: body)
	}

	@Test("An empty part header value doesn't trap",
	      arguments: ["Content-Disposition:", "Content-Type:", ":", "C:"])
	func emptyPartHeaderValue(_ line: String) {
		let body = Array("--abc\r\n\(line)\r\n\r\nv\r\n--abc--\r\n".utf8)
		_ = try? MimeReader.parse(contentType: "multipart/form-data; boundary=abc", body: body)
	}

	// MARK: Range

	/// A 10-byte temp file served by FileOutput; returns the head for `range` and the body.
	private func serve(range: String) async throws -> (HTTPHead?, [UInt8]) {
		let path = NSTemporaryDirectory() + "perfect-nio-range-\(UUID().uuidString)"
		try Data("0123456789".utf8).write(to: URL(fileURLWithPath: path))
		defer { try? FileManager.default.removeItem(atPath: path) }
		let output = try FileOutput(localPath: path)
		let head = output.head(request: requestInfo([("Range", range)]))
		return (head, try await drain(output))
	}

	@Test("A Range end at or near Int.max doesn't trap",
	      arguments: ["bytes=0-9223372036854775807", "bytes=2-9223372036854775806", "bytes=9223372036854775807-9223372036854775807"])
	func rangeEndAtIntMax(_ range: String) async throws {
		_ = try await serve(range: range)
	}

	@Test func rangeRequests() async throws {
		func check(_ range: String, _ expected: String, contentRange: String?,
		           sourceLocation: SourceLocation = #_sourceLocation) async throws {
			let (head, body) = try await serve(range: range)
			#expect(String(decoding: body, as: UTF8.self) == expected, sourceLocation: sourceLocation)
			#expect(head?.headers.first(name: "content-range") == contentRange, sourceLocation: sourceLocation)
			#expect(head?.headers.first(name: "content-length") == "\(expected.utf8.count)", sourceLocation: sourceLocation)
			#expect(head?.status == (contentRange == nil ? .ok : .partialContent), sourceLocation: sourceLocation)
		}
		try await check("bytes=2-4", "234", contentRange: "bytes 2-4/10")
		try await check("bytes=7-", "789", contentRange: "bytes 7-9/10")
		try await check("bytes=8-100", "89", contentRange: "bytes 8-9/10")
		try await check("bytes=0-9223372036854775807", "0123456789", contentRange: "bytes 0-9/10")
		// Multiple ranges are comma-separated (RFC 9110 §14.1.1); only the first is served.
		try await check("bytes=1-2, 5-6", "12", contentRange: "bytes 1-2/10")
		// Unsatisfiable or malformed ranges are ignored and the whole file is served.
		try await check("bytes=10-", "0123456789", contentRange: nil)
		try await check("bytes=5-3", "0123456789", contentRange: nil)
		try await check("bytes=-3", "0123456789", contentRange: nil)
		try await check("items=0-1", "0123456789", contentRange: nil)
	}
}
