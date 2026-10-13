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
}
