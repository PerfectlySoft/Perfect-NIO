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

/// Decodes through the container APIs RequestDecoder doesn't support.
private struct Nested: Decodable {
	enum Keys: String, CodingKey { case a, b }
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: Keys.self)
		_ = try c.nestedContainer(keyedBy: Keys.self, forKey: .a)
	}
}
private struct NestedUnkeyed: Decodable {
	enum Keys: String, CodingKey { case a }
	init(from decoder: Decoder) throws {
		_ = try decoder.container(keyedBy: Keys.self).nestedUnkeyedContainer(forKey: .a)
	}
}
private struct Super: Decodable {
	enum Keys: String, CodingKey { case a }
	init(from decoder: Decoder) throws {
		_ = try decoder.container(keyedBy: Keys.self).superDecoder()
	}
}
private struct UnkeyedNested: Decodable {
	init(from decoder: Decoder) throws {
		var c = try decoder.unkeyedContainer()
		_ = try c.nestedUnkeyedContainer()
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
		// "*" stands only for codings not listed; an explicit q=0 refuses one.
		#expect(encoding("gzip;q=0, *") == "deflate")
		#expect(encoding("gzip;q=0, deflate;q=0, *") == nil)
		#expect(encoding("*") == "gzip")
	}

	@Test("compressed() always sends Vary: Accept-Encoding", arguments: ["gzip", "identity", ""])
	func compressedVaries(_ acceptEncoding: String) {
		for size in [100, 20_000] {
			let output = CompressedOutput(source: BytesOutput(body: Array(repeating: 65, count: size)))
			let headers = acceptEncoding.isEmpty ? [] : [("Accept-Encoding", acceptEncoding)]
			let head = output.head(request: requestInfo(headers))
			#expect(head?.headers[canonicalForm: "vary"].map { $0.lowercased() } == ["accept-encoding"],
			        "size \(size)")
		}
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

	// MARK: Conditional requests

	@Test func conditionalFileRequests() async throws {
		let path = NSTemporaryDirectory() + "perfect-nio-cond-\(UUID().uuidString)"
		try Data("0123456789".utf8).write(to: URL(fileURLWithPath: path))
		defer { try? FileManager.default.removeItem(atPath: path) }
		/// FileOutput's head for `headers` on the 10-byte file, and the body that follows.
		func serve(_ headers: [(String, String)]) async throws -> (HTTPHead?, String, FileOutput) {
			let output = try FileOutput(localPath: path)
			let head = output.head(request: requestInfo(headers))
			return (head, String(decoding: try await drain(output), as: UTF8.self), output)
		}
		let (plain, _, _) = try await serve([])
		let eTag = try #require(plain?.headers.first(name: "etag"))
		let lastModified = try #require(plain?.headers.first(name: "last-modified"))
		// The ETag is a quoted string, as RFC 9110 requires.
		#expect(eTag.hasPrefix("\"") && eTag.hasSuffix("\"") && eTag.count > 2)
		#expect(lastModified.hasSuffix(" GMT"))

		// If-Range: a matching validator gets the range, a stale one the whole file. The range
		// used to be served whatever If-Range said, splicing old and new content on resume.
		var (head, body, _) = try await serve([("Range", "bytes=2-4"), ("If-Range", eTag)])
		#expect(head?.status == .partialContent); #expect(body == "234")
		(head, body, _) = try await serve([("Range", "bytes=2-4"), ("If-Range", "\"stale\"")])
		#expect(head?.status == .ok); #expect(body == "0123456789")
		(head, body, _) = try await serve([("Range", "bytes=2-4"), ("If-Range", "W/" + eTag)])
		#expect(head?.status == .ok, "a weak tag never satisfies If-Range")
		(head, body, _) = try await serve([("Range", "bytes=2-4"), ("If-Range", lastModified)])
		#expect(head?.status == .partialContent); #expect(body == "234")
		(head, body, _) = try await serve([("Range", "bytes=2-4"), ("If-Range", "Thu, 01 Jan 1970 00:00:00 GMT")])
		#expect(head?.status == .ok); #expect(body == "0123456789")

		// If-None-Match: lists, weak tags and "*" all match (weak comparison).
		for value in [eTag, "\"x\", " + eTag, "W/" + eTag, "*"] {
			(head, body, _) = try await serve([("If-None-Match", value)])
			#expect(head?.status == .notModified, "\(value)")
			#expect(body == "")
		}
		(head, _, _) = try await serve([("If-None-Match", "\"other\"")])
		#expect(head?.status == .ok)
	}

	// MARK: FileOutput errors

	@Test func fileOutputErrorDoesNotNameTheLocalPath() async throws {
		let path = NSTemporaryDirectory() + "perfect-nio-secret-\(UUID().uuidString)"
		try Data("0123456789".utf8).write(to: URL(fileURLWithPath: path))
		let output = try FileOutput(localPath: path)
		_ = output.head(request: requestInfo([]))
		try FileManager.default.removeItem(atPath: path)
		do {
			_ = try await drain(output)
			Issue.record("expected an error for a file removed after the head was sent")
		} catch let error as ErrorOutput {
			#expect(!error.description.contains("perfect-nio-secret"), "\(error.description)")
			let body = try await drain(error)
			#expect(!String(decoding: body, as: UTF8.self).contains("perfect-nio-secret"))
		}
	}

	@Test func fileOutputServesIndexHTMLForADirectory() async throws {
		let dir = NSTemporaryDirectory() + "perfect-nio-dir-\(UUID().uuidString)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		try Data("<p>index</p>".utf8).write(to: URL(fileURLWithPath: dir + "/index.html"))
		let output = try FileOutput(localPath: dir)
		let head = output.head(request: requestInfo([]))
		#expect(head?.headers.first(name: "content-type")?.hasPrefix("text/html") == true)
		#expect(String(decoding: try await drain(output), as: UTF8.self) == "<p>index</p>")
	}

	@Test func fileOutputForADirectoryWithoutIndexIsNotFound() throws {
		let dir = NSTemporaryDirectory() + "perfect-nio-dir-\(UUID().uuidString)"
		try FileManager.default.createDirectory(atPath: dir + "/index.html", withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		// No index.html file (here it is itself a directory): 404, not a trap reading a directory.
		#expect(throws: ErrorOutput.self) { try FileOutput(localPath: dir) }
	}

	@Test func fileOutputStreamsALargeFileInChunks() async throws {
		let path = NSTemporaryDirectory() + "perfect-nio-large-\(UUID().uuidString)"
		let bytes = (0..<(FileOutput.chunkSize * 2 + 1000)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
		try Data(bytes).write(to: URL(fileURLWithPath: path))
		defer { try? FileManager.default.removeItem(atPath: path) }
		let output = try FileOutput(localPath: path)
		_ = output.head(request: requestInfo([("Range", "bytes=100-")]))
		var chunks: [Int] = []
		var body: [UInt8] = []
		while let chunk = try await output.nextChunk(allocator: ByteBufferAllocator()) {
			chunks.append(chunk.readableBytes)
			body += chunk.readableBytesView
		}
		#expect(chunks.allSatisfy { $0 <= FileOutput.chunkSize })
		#expect(chunks.count == 3)
		#expect(body == Array(bytes[100...]))
	}

	// MARK: Route matching

	@Test func wildcardRouteDoesNotMatchAPathWithMoreComponents() throws {
		let routes = try root().dir(
			root().public.wild { (_: HTTPRequest, name: String) in name }.text(),
			root().v1_0.x { "x" }.text()
		)
		let finder = try RouteFinderDual(routes)
		#expect(finder.route(.GET, "/public/a") != nil)
		#expect(finder.route(.GET, "/public/\u{1F600}") != nil)
		// The regex used to be matched over the path's Character count instead of its UTF-16
		// length, so each multi-unit character cut a code unit off the end of the match. Enough
		// of them hid a trailing "/secret" and the request reached "/public/*".
		let emoji = String(repeating: "\u{1F600}", count: 7)
		#expect(finder.route(.GET, "/public/\(emoji)/secret") == nil)
		#expect(finder.route(.GET, "/public/e\u{301}e\u{301}/b") == nil)
	}

	@Test func routeComponentsAreMatchedLiterally() throws {
		let routes = try root().dir(
			root().path("v1.0").wild { (_: HTTPRequest, name: String) in name }.text(),
			root().path("a+b").wild { (_: HTTPRequest, name: String) in name }.text()
		)
		let finder = try RouteFinderDual(routes)
		#expect(finder.route(.GET, "/v1.0/x") != nil)
		#expect(finder.route(.GET, "/a+b/x") != nil)
		// A route component was spliced into the regex unescaped: "." matched any character
		// and "+" was a quantifier.
		#expect(finder.route(.GET, "/v1x0/x") == nil)
		#expect(finder.route(.GET, "/aab/x") == nil)
	}

	// MARK: Request decoding

	private struct NameForm: Decodable { let name: String }
	private struct UploadForm: Decodable { let name: FileUpload }

	/// A file part decoded into a String field used to yield the server's temp file path.
	@Test func filePartDecodesOnlyAsFileUpload() throws {
		let body = Array(("--abc\r\nContent-Disposition: form-data; name=\"name\"; filename=\"a.txt\"\r\n" +
			"Content-Type: text/plain\r\n\r\nhello\r\n--abc--\r\n").utf8)
		let reader = try MimeReader.parse(contentType: "multipart/form-data; boundary=abc", body: body)
		let request = NIOAsyncHTTPRequest(head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/"),
		                                  body: [], channel: nil, isTLS: false)
		#expect(throws: DecodingError.self) { _ = try request.decode(NameForm.self, content: .multiPartForm(reader)) }
		let upload = try request.decode(UploadForm.self, content: .multiPartForm(reader))
		#expect(upload.name.fileName == "a.txt")
		#expect(upload.name.fileSize == 5)
	}

	@Test("Container APIs the form decoder lacks throw instead of trapping", arguments: 0..<4)
	func unsupportedDecoderContainers(_ index: Int) {
		let type = ([Nested.self, NestedUnkeyed.self, Super.self, UnkeyedNested.self] as [any Decodable.Type])[index]
		let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/x?a=1&b=2")
		let request = NIOAsyncHTTPRequest(head: head, body: [], channel: nil, isTLS: false)
		#expect(throws: DecodingError.self) {
			_ = try request.decode(type, content: .urlForm(QueryDecoder(Array("a=1".utf8))))
		}
	}
}

// MARK: - Public API shape

/// Compile-time checks: these public value types can cross concurrency domains, and
/// RouteDescription's uri is readable outside the module (the README uses it).
private struct ReadmeSession: Sendable { let userId: String }
private func readmeSession(from req: any HTTPRequest) -> ReadmeSession? {
	req.headers["Authorization"].first.map { ReadmeSession(userId: $0) }
}

@Suite("Public API")
struct PublicAPITests {
	private func requireSendable<T: Sendable>(_: T.Type) {}

	@Test func valueTypesAreSendable() {
		requireSendable(HTTPHead.self)
		requireSendable(HTTPRequestInfo.self)
		requireSendable(QueryDecoder.self)
		requireSendable(FileUpload.self)
		requireSendable(RouteDescription.self)
		requireSendable(Server.self)
	}

	/// The README's auth pattern: a plain function taking `any HTTPRequest` passed to `root`.
	/// Before HTTPRequest was Sendable, Swift 6.2 warned that converting it to the route's
	/// async closure crossed an isolation boundary (an error with warnings as errors).
	@Test func authPatternBuilds() {
		requireSendable((any HTTPRequest).self)
		let routes = root(readmeSession(from:)).statusCheck { $0 == nil ? .unauthorized : .ok }
			.unwrap { $0.userId }.text()
		#expect(!routes.describe.isEmpty)
	}

	@Test func routeDescriptionsExposeTheirURI() {
		let routes = root().path("a").map { "a" }.text()
		#expect(routes.describe.map(\.uri) == ["/a"])
	}
}
