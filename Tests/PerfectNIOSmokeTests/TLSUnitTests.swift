//
//  TLSUnitTests.swift
//  PerfectNIOSmokeTests
//
//  Pure unit tests for the multi-tenant TLS components.
//  No network I/O, no actual TLS handshake, no external certs required.
//

import XCTest
import Foundation
import NIO
import NIOCore
import NIOSSL
@testable import PerfectNIO

// MARK: - SNIPeekHandler — ClientHello parser

final class SNIParserTests: XCTestCase {

	// Builds a minimal TLS 1.2 ClientHello containing an SNI extension for `hostname`.
	// Layout:
	//   TLS record header (5)  + handshake header (4)
	//   + version (2) + random (32) + sid_len (1) + cipher_suites (4) + compression (2)
	//   + extensions_total_len (2) + SNI extension (4 + 2 + 1 + 2 + name_len)
	private func clientHello(sni hostname: String? = "example.com") -> ByteBuffer {
		let nameBytes = hostname.map { Array($0.utf8) } ?? []
		let nameLen = nameBytes.count
		// SNI extension data: list_len(2) + name_type(1) + name_len(2) + name
		let sniDataLen = 2 + 1 + 2 + nameLen     // 5 + name
		let sniExtLen  = 4 + sniDataLen            // type(2)+len(2)+data
		let extTotalLen = hostname != nil ? sniExtLen : 0

		// ClientHello body length
		let chLen = 2 + 32 + 1 + 4 + 2 + (extTotalLen > 0 ? 2 + extTotalLen : 0)
		// Handshake message: hs_header(4) + ClientHello
		let hsLen = 4 + chLen
		// TLS record: record_header(5) + handshake_message
		let totalLen = 5 + hsLen

		var buf = ByteBufferAllocator().buffer(capacity: totalLen)

		// TLS record header
		buf.writeInteger(UInt8(0x16))         // content_type = handshake
		buf.writeInteger(UInt8(0x03))         // legacy version hi
		buf.writeInteger(UInt8(0x01))         // legacy version lo (TLS 1.0)
		buf.writeInteger(UInt16(hsLen))       // record length

		// Handshake header
		buf.writeInteger(UInt8(0x01))         // type = ClientHello
		buf.writeInteger(UInt8(0))            // length (24-bit) hi
		buf.writeInteger(UInt16(chLen))       // length (24-bit) lo

		// ClientHello: version
		buf.writeInteger(UInt8(0x03))         // TLS 1.2 hi
		buf.writeInteger(UInt8(0x03))         // TLS 1.2 lo
		// random (32 bytes)
		for i: UInt8 in 0..<32 { buf.writeInteger(i) }
		// session_id (empty)
		buf.writeInteger(UInt8(0))
		// cipher_suites (one suite)
		buf.writeInteger(UInt16(2))
		buf.writeInteger(UInt8(0x00))
		buf.writeInteger(UInt8(0x2F))         // TLS_RSA_WITH_AES_128_CBC_SHA
		// compression_methods (null)
		buf.writeInteger(UInt8(1))
		buf.writeInteger(UInt8(0))

		// Extensions
		if let hostname {
			buf.writeInteger(UInt16(sniExtLen))   // extensions_total_length
			buf.writeInteger(UInt16(0x0000))      // ext_type = server_name
			buf.writeInteger(UInt16(sniDataLen))  // ext data length
			buf.writeInteger(UInt16(1 + 2 + nameLen)) // server_name_list_length
			buf.writeInteger(UInt8(0x00))         // name_type = host_name
			buf.writeInteger(UInt16(nameLen))
			buf.writeBytes(nameBytes)
		}

		return buf
	}

	// MARK: Tests

	func testExtractSNI_found() {
		let buf = clientHello(sni: "example.com")
		let result = SNIPeekHandler.extractSNI(from: buf)
		guard case .found(let host) = result else {
			return XCTFail("expected .found, got \(result)")
		}
		XCTAssertEqual(host, "example.com")
	}

	func testExtractSNI_multiSegmentHostname() {
		let buf = clientHello(sni: "tenant42.acme-corp.example.com")
		let result = SNIPeekHandler.extractSNI(from: buf)
		guard case .found(let host) = result else {
			return XCTFail("expected .found, got \(result)")
		}
		XCTAssertEqual(host, "tenant42.acme-corp.example.com")
	}

	func testExtractSNI_incomplete_tooShort() {
		// Only 10 bytes — way below the 43-byte minimum
		var buf = ByteBufferAllocator().buffer(capacity: 10)
		buf.writeBytes([UInt8](repeating: 0x16, count: 10))
		let result = SNIPeekHandler.extractSNI(from: buf)
		XCTAssertEqual(result, .incomplete)
	}

	func testExtractSNI_incomplete_recordTruncated() {
		// Build the full buffer but slice off the last byte so recordLen > available bytes
		var full = clientHello(sni: "example.com")
		let truncated = full.getSlice(at: 0, length: full.readableBytes - 1)!
		let result = SNIPeekHandler.extractSNI(from: truncated)
		XCTAssertEqual(result, .incomplete)
	}

	func testExtractSNI_absent_notHandshake() {
		var buf = ByteBufferAllocator().buffer(capacity: 50)
		buf.writeBytes([UInt8](repeating: 0x15, count: 50)) // content_type = alert, not handshake
		let result = SNIPeekHandler.extractSNI(from: buf)
		XCTAssertEqual(result, .absent)
	}
}

extension SNIPeekHandler.SNIResult: Equatable {
	public static func == (lhs: SNIPeekHandler.SNIResult, rhs: SNIPeekHandler.SNIResult) -> Bool {
		switch (lhs, rhs) {
		case (.incomplete, .incomplete): return true
		case (.absent, .absent): return true
		case (.found(let a), .found(let b)): return a == b
		default: return false
		}
	}
}

// MARK: - TLSContextManager

final class TLSContextManagerTests: XCTestCase {

	func testContextForUnregisteredHostname_noDefault_returnsNil() async throws {
		let mgr = try TLSContextManager()
		let ctx = await mgr.context(for: "unknown.example.com")
		XCTAssertNil(ctx)
	}

	func testContextForNil_noDefault_returnsNil() async throws {
		let mgr = try TLSContextManager()
		let ctx = await mgr.context(for: nil)
		XCTAssertNil(ctx)
	}

	func testRemoveCertificate_fallsBackToNil() async throws {
		let mgr = try TLSContextManager()
		let (cert, key) = try Self.selfSignedConfig()
		try await mgr.setCertificate(for: "host.example.com", config: cert)
		let ctxBefore = await mgr.context(for: "host.example.com")
		XCTAssertNotNil(ctxBefore)
		await mgr.removeCertificate(for: "host.example.com")
		let ctxAfter = await mgr.context(for: "host.example.com")
		XCTAssertNil(ctxAfter)
		_ = key // suppress unused warning
	}

	func testContextLookup_domainTakesPrecedenceOverDefault() async throws {
		let (defaultCfg, _) = try Self.selfSignedConfig()
		let (domainCfg, _) = try Self.selfSignedConfig()
		let mgr = try TLSContextManager(default: defaultCfg)
		try await mgr.setCertificate(for: "specific.example.com", config: domainCfg)

		let defaultCtx = await mgr.context(for: "other.example.com")
		let domainCtx  = await mgr.context(for: "specific.example.com")
		XCTAssertNotNil(defaultCtx)
		XCTAssertNotNil(domainCtx)
		// The two contexts are different objects (different certs)
		XCTAssertFalse(defaultCtx === domainCtx,
		               "domain-specific context should differ from default")
	}

	/// Creates a minimal self-signed TLSConfiguration for testing.
	/// Returns the config and the private key bytes (suppresses unused-var).
	private static func selfSignedConfig() throws -> (TLSConfiguration, NIOSSLPrivateKey) {
		// Generate a test cert using openssl in a temp dir.
		// If openssl is unavailable the test is skipped.
		let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nio-tls-test-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tmp) }

		let certPath = tmp.appendingPathComponent("cert.pem").path
		let keyPath  = tmp.appendingPathComponent("key.pem").path

		let result = Process.run("/usr/bin/openssl", arguments: [
			"req", "-x509", "-newkey", "rsa:2048", "-nodes",
			"-keyout", keyPath, "-out", certPath,
			"-days", "1",
			"-subj", "/CN=test.local"
		])
		guard result == 0 else {
			throw XCTSkip("openssl unavailable — skipping TLSContextManager cert tests")
		}

		let certs = try NIOSSLCertificate.fromPEMFile(certPath)
		let key   = try NIOSSLPrivateKey(file: keyPath, format: .pem)
		let cfg   = TLSConfiguration.makeServerConfiguration(
			certificateChain: certs.map { .certificate($0) },
			privateKey: .privateKey(key)
		)
		return (cfg, key)
	}
}

extension Process {
	/// Synchronously run a process, returning the exit code.
	fileprivate static func run(_ path: String, arguments: [String]) -> Int32 {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: path)
		p.arguments = arguments
		p.standardOutput = FileHandle.nullDevice
		p.standardError  = FileHandle.nullDevice
		try? p.run()
		p.waitUntilExit()
		return p.terminationStatus
	}
}

// MARK: - RedirectOutput

final class RedirectOutputTests: XCTestCase {

	private let dummyInfo = HTTPRequestInfo(
		head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/"),
		options: .init()
	)

	func testDefaultStatus_isPermanentRedirect() {
		let output = RedirectOutput(to: "https://example.com/")
		let head = output.head(request: dummyInfo)
		XCTAssertEqual(head?.status, .permanentRedirect)
	}

	func testLocationHeader() {
		let dest = "https://example.com/path?q=1"
		let output = RedirectOutput(to: dest)
		let head = output.head(request: dummyInfo)
		XCTAssertEqual(head?.headers.first(name: "location"), dest)
	}

	func testCustomStatus_301() {
		let output = RedirectOutput(to: "https://example.com/", status: .movedPermanently)
		let head = output.head(request: dummyInfo)
		XCTAssertEqual(head?.status, .movedPermanently)
	}

	func testNoBody() async throws {
		let output = RedirectOutput(to: "https://example.com/")
		let chunk = try await output.nextChunk(allocator: ByteBufferAllocator())
		XCTAssertNil(chunk, "redirect responses must have no body")
	}
}

// MARK: - ACMEChallengeResponder

final class ACMEChallengeResponderTests: XCTestCase {

	func testNoToken_returnsNil() async {
		let acme = ACMEChallengeResponder()
		let result = await acme.response(for: "sometoken")
		XCTAssertNil(result)
	}

	func testAddedToken_returnsKeyAuthorization() async {
		let acme = ACMEChallengeResponder()
		await acme.addChallenge(token: "abc123", keyAuthorization: "abc123.thumbprint")
		let result = await acme.response(for: "abc123")
		XCTAssertEqual(result, "abc123.thumbprint")
	}

	func testRemovedToken_returnsNil() async {
		let acme = ACMEChallengeResponder()
		await acme.addChallenge(token: "abc123", keyAuthorization: "abc123.thumbprint")
		await acme.removeChallenge(token: "abc123")
		let result = await acme.response(for: "abc123")
		XCTAssertNil(result)
	}

	func testUnknownToken_neverMatchesRegistered() async {
		let acme = ACMEChallengeResponder()
		await acme.addChallenge(token: "real-token", keyAuthorization: "real-token.thumbprint")
		let other = await acme.response(for: "other-token")
		XCTAssertNil(other)
	}

	func testHasPendingChallenges() async {
		let acme = ACMEChallengeResponder()
		let before = await acme.hasPendingChallenges
		XCTAssertFalse(before)
		await acme.addChallenge(token: "t", keyAuthorization: "k")
		let during = await acme.hasPendingChallenges
		XCTAssertTrue(during)
		await acme.removeChallenge(token: "t")
		let after = await acme.hasPendingChallenges
		XCTAssertFalse(after)
	}
}
