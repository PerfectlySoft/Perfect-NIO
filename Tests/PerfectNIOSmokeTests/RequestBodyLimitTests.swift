//
//  RequestBodyLimitTests.swift
//  PerfectNIOSmokeTests
//
//  Server.maxRequestBodySize: oversized bodies get 413 before they're buffered,
//  whether the size is declared (Content-Length) or only discovered while
//  reading a chunked body.
//

import Testing
import Foundation
import NIOCore
@testable import PerfectNIO

/// Counts route invocations, so tests can check a refused body never reached the handler.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// POST /echo replies with the number of body bytes the handler received.
private func echoRoutes(_ calls: CallCounter) -> Routes<HTTPRequest, HTTPOutput> {
    root().POST.path("echo").readBody { (_, content) -> String in
        calls.increment()
        switch content {
        case .other(let bytes): return "\(bytes.count)"
        case .none: return "0"
        default: return "unexpected content type"
        }
    }.text()
}

private func withLimitedServer(_ limit: Int?,
                               _ body: (_ port: Int, _ calls: CallCounter) async throws -> Void) async throws {
    let calls = CallCounter()
    try await Server(routes: echoRoutes(calls), port: 0, maxRequestBodySize: limit)
        .withServer { port in try await body(port, calls) }
}

private let octets = [("Content-Type", "application/octet-stream")]

@Suite("Request body size limit")
struct RequestBodyLimitTests {

    @Test func defaultIs10MiB() {
        let server = Server(routes: root().GET.path("x").map { "x" }.text(), port: 0)
        #expect(server.maxRequestBodySize == 10 * 1024 * 1024)
        #expect(Server.defaultMaxRequestBodySize == 10 * 1024 * 1024)
    }

    /// Uses only API that exists on main, so it shows the bug there: with no limit the server
    /// waits to buffer the declared 11 MiB and the client times out with no response.
    @Test func defaultLimitRefusesALargeDeclaredBodyWithoutReadingIt() async throws {
        let calls = CallCounter()
        try await Server(routes: echoRoutes(calls), port: 0).withServer { port in
            let head = rawHead("POST", "/echo", octets + [("Content-Length", "\(11 * 1024 * 1024)")])
            let r = await rawHTTP(port: port, [head, Array(repeating: 0x61, count: 100)])
            #expect(r.status == 413)
            #expect(r.body == "Request body is too large.")
            #expect(r.text.lowercased().contains("connection: close"))
            #expect(r.closed)
            #expect(calls.count == 0)
        }
    }

    @Test func contentLengthOverTheLimitIsRefused() async throws {
        try await withLimitedServer(1024) { port, calls in
            let head = rawHead("POST", "/echo", octets + [("Content-Length", "1025")])
            let r = await rawHTTP(port: port, [head])
            #expect(r.status == 413)
            #expect(r.closed)
            // Refused from the head alone: the server waits at most the drain time for a body
            // that never comes, not the client's 5 s read timeout.
            #expect(r.elapsed < 4)
            #expect(calls.count == 0)
        }
    }

    @Test func bodyAtTheLimitIsAccepted() async throws {
        try await withLimitedServer(1024) { port, calls in
            let body = [UInt8](repeating: 0x62, count: 1024)
            let head = rawHead("POST", "/echo", octets + [("Content-Length", "1024"), ("Connection", "close")])
            let r = await rawHTTP(port: port, [head, body])
            #expect(r.status == 200)
            #expect(r.body == "1024")
            #expect(calls.count == 1)
        }
    }

    @Test func chunkedBodyAtTheLimitIsAccepted() async throws {
        try await withLimitedServer(1024) { port, calls in
            let head = rawHead("POST", "/echo", octets + [("Transfer-Encoding", "chunked"), ("Connection", "close")])
            let parts = [head] + (0..<4).map { _ in rawChunk([UInt8](repeating: 0x63, count: 256)) } + [rawLastChunk]
            let r = await rawHTTP(port: port, parts)
            #expect(r.status == 200)
            #expect(r.body == "1024")
            #expect(calls.count == 1)
        }
    }

    /// No Content-Length, so the size is only known once the bytes arrive. The client stops
    /// after 1025 bytes without ending the body; it still gets a 413.
    @Test func chunkedBodyOverTheLimitIsRefusedWhileStreaming() async throws {
        try await withLimitedServer(1024) { port, calls in
            let head = rawHead("POST", "/echo", octets + [("Transfer-Encoding", "chunked")])
            let parts = [head] + (0..<4).map { _ in rawChunk([UInt8](repeating: 0x64, count: 256)) } + [rawChunk([0x64])]
            let r = await rawHTTP(port: port, parts)
            #expect(r.status == 413)
            #expect(r.closed)
            #expect(calls.count == 0)
        }
    }

    /// A client that writes the whole oversized body before reading still gets the 413:
    /// the server drains the rest of the body instead of resetting the connection under it.
    @Test func clientThatSendsTheWholeBodyStillSeesThe413() async throws {
        try await withLimitedServer(1024) { port, calls in
            let size = 300_000
            let head = rawHead("POST", "/echo", octets + [("Content-Length", "\(size)")])
            let r = await rawHTTP(port: port, [head, [UInt8](repeating: 0x65, count: size)])
            #expect(r.status == 413)
            #expect(r.closed)
            #expect(calls.count == 0)
        }
    }

    /// With Expect: 100-continue the client waits for the go-ahead, so the server closes right
    /// after the 413 rather than waiting to drain a body that won't be sent.
    @Test func expectContinueIsRefusedImmediately() async throws {
        try await withLimitedServer(1024) { port, calls in
            let head = rawHead("POST", "/echo", octets + [("Content-Length", "5000"), ("Expect", "100-continue")])
            let r = await rawHTTP(port: port, [head])
            #expect(r.status == 413)
            #expect(r.closed)
            #expect(r.elapsed < 1.5)
            #expect(calls.count == 0)
        }
    }

    /// Expect: 100-continue doesn't skip the drain once the body is already arriving (NIO never
    /// sends 100 Continue, so clients start sending after their own timeout). The body here
    /// never ends, so the server drains until the 2 s deadline instead of closing at once.
    @Test func expectContinueWithBodyAlreadyArrivingIsDrained() async throws {
        try await withLimitedServer(1024) { port, calls in
            let head = rawHead("POST", "/echo", octets + [("Transfer-Encoding", "chunked"), ("Expect", "100-continue")])
            let r = await rawHTTP(port: port, [head, rawChunk([UInt8](repeating: 0x6B, count: 2048))])
            #expect(r.status == 413)
            #expect(r.closed)
            #expect(r.elapsed > 1.5)
            #expect(calls.count == 0)
        }
    }

    /// A refused request ends the connection: a pipelined request behind it isn't served.
    @Test func connectionIsNotReusedAfterA413() async throws {
        try await withLimitedServer(16) { port, calls in
            let first = rawHead("POST", "/echo", octets + [("Content-Length", "17")]) + [UInt8](repeating: 0x66, count: 17)
            let second = rawHead("POST", "/echo", octets + [("Content-Length", "1")]) + [0x67]
            let r = await rawHTTP(port: port, [first + second])
            #expect(r.status == 413)
            #expect(r.closed)
            #expect(r.text.components(separatedBy: "HTTP/1.1 ").count == 2) // one response only
            #expect(calls.count == 0)
        }
    }

    @Test func keepAliveContinuesUnderTheLimit() async throws {
        try await withLimitedServer(1024) { port, calls in
            let first = rawHead("POST", "/echo", octets + [("Content-Length", "3")]) + Array("abc".utf8)
            let second = rawHead("POST", "/echo", octets + [("Content-Length", "2"), ("Connection", "close")]) + Array("de".utf8)
            let r = await rawHTTP(port: port, [first, second])
            #expect(r.text.components(separatedBy: "HTTP/1.1 200").count == 3)
            #expect(calls.count == 2)
        }
    }

    @Test func nilMeansNoLimit() async throws {
        try await withLimitedServer(nil) { port, calls in
            let size = 12 * 1024 * 1024
            let head = rawHead("POST", "/echo", octets + [("Content-Length", "\(size)"), ("Connection", "close")])
            let r = await rawHTTP(port: port, [head, [UInt8](repeating: 0x68, count: size)], timeout: 20)
            #expect(r.status == 200)
            #expect(r.body == "\(size)")
            #expect(calls.count == 1)
        }
    }

    /// A request with an `Upgrade: websocket` header is held while its route is resolved (the
    /// handler runs, slowly here). Before the fix the router buffered everything that arrived
    /// meanwhile, so a client could stream far more than the limit into memory; the server
    /// accepted ~64 MiB here. Now reads stop during resolution, so only what fits in socket
    /// buffers plus the 1 MiB drain is taken before the 413 and close.
    @Test func upgradeHeaderDoesNotBypassTheLimit() async throws {
        let routes = root().POST.path("slow").map { () async throws -> String in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return "slow"
        }.text()
        try await Server(routes: routes, port: 0, maxRequestBodySize: 1024).withServer { port in
            let size = 64 * 1024 * 1024
            let head = rawHead("POST", "/slow", octets + [
                ("Content-Length", "\(size)"), ("Connection", "Upgrade"), ("Upgrade", "websocket"),
                ("Sec-WebSocket-Version", "13"), ("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
            ])
            let r = await rawHTTP(port: port, [head, [UInt8](repeating: 0x6A, count: size)], timeout: 10)
            #expect(r.sent < 16 * 1024 * 1024)
        }
    }

    /// Multipart bodies are buffered whole before parsing, so they're held to the same limit.
    @Test func multipartUploadOverTheLimitIsRefused() async throws {
        let boundary = "LimitBoundary"
        var body = Array("--\(boundary)\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.bin\"\r\n\r\n".utf8)
        body += [UInt8](repeating: 0x69, count: 2048)
        body += Array("\r\n--\(boundary)--\r\n".utf8)
        try await withLimitedServer(1024) { port, calls in
            let head = rawHead("POST", "/echo", [("Content-Type", "multipart/form-data; boundary=\(boundary)"),
                                                 ("Content-Length", "\(body.count)")])
            let r = await rawHTTP(port: port, [head, body])
            #expect(r.status == 413)
            #expect(calls.count == 0)
        }
    }
}
