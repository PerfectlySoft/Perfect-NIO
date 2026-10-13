//
//  ProtocolHardeningTests.swift
//  PerfectNIOSmokeTests
//
//  Byte-level HTTP/1.1 behaviour a hostile or broken client can trigger: connections that
//  never finish a request, malformed framing, and response framing the server must get
//  right for keep-alive clients and proxies.
//

import Testing
import Foundation
import NIOCore
import NIOHTTP1
@testable import PerfectNIO

private func raw(_ s: String) -> [UInt8] { Array(s.utf8) }

private let tenBytes = root().path("ten").map { BytesOutput(body: Array("0123456789".utf8)) as HTTPOutput }

/// A body of unknown length: three chunks, no Content-Length.
private final class StreamOutput: HTTPOutput, @unchecked Sendable {
    private var remaining = ["ab", "cd", "ef"]
    override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
        remaining.isEmpty ? nil : allocator.buffer(string: remaining.removeFirst())
    }
}

/// `count` chunks of `size` bytes, `delay` seconds apart; no Content-Length.
private final class SlowOutput: HTTPOutput, @unchecked Sendable {
    private var remaining: Int
    private let size: Int
    private let delay: Double
    init(count: Int, size: Int = 10, delay: Double) {
        remaining = count; self.size = size; self.delay = delay
    }
    override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
        guard remaining > 0 else { return nil }
        remaining -= 1
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return allocator.buffer(repeating: 0x61, count: size)
    }
}

@Suite("HTTP protocol hardening")
struct ProtocolHardeningTests {

    // MARK: Idle connections

    /// Before, the idle timeout was installed only once a request head had been routed, so a
    /// client that connected and sent nothing, or only part of a head, held the connection
    /// (and a file descriptor) open for as long as it liked.
    @Test("The idle timeout applies before the first request",
          arguments: [("silent", ""), ("partial head", "GET /ten HTTP/1.1\r\nHo")])
    func idleTimeoutBeforeFirstRequest(_ name: String, _ bytes: String) async throws {
        try await Server(routes: tenBytes, port: 0, idleTimeout: .milliseconds(500)).withServer { port in
            let r = await rawHTTP(port: port, bytes.isEmpty ? [] : [raw(bytes)], timeout: 20)
            #expect(r.closed, "\(name): the server never closed the connection")
            #expect(r.elapsed < 10, "\(name)")
        }
    }

    /// The idle timeout used to measure reads only, so a response that took longer than the
    /// timeout to deliver (a slow stream, a long poll, a slow download) was cut off mid-body.
    @Test func slowResponseOutlivesTheIdleTimeout() async throws {
        let routes = try root().dir(
            root().path("slow").map { SlowOutput(count: 6, delay: 0.6) as HTTPOutput },
            root().path("poll").map { () async throws -> HTTPOutput in
                try await Task.sleep(nanoseconds: 3_000_000_000)
                return TextOutput("late")
            }
        )
        // Timeouts well clear of scheduling delays on a loaded or emulated runner: a 2 s
        // timeout against responses that take 3 s or more to finish.
        try await Server(routes: routes, port: 0, idleTimeout: .seconds(2)).withServer { port in
            let slow = await rawHTTP(port: port, [rawHead("GET", "/slow", [("Connection", "close")])], timeout: 20)
            #expect(slow.text.hasSuffix("0\r\n\r\n"), "\(slow.text.debugDescription)")
            #expect(slow.text.components(separatedBy: "aaaaaaaaaa").count == 7)
            let poll = await rawHTTP(port: port, [rawHead("GET", "/poll", [("Connection", "close")])], timeout: 20)
            #expect(poll.body == "late", "\(poll.text.debugDescription)")
        }
    }

    @Test func slowUploadIsNotCutOff() async throws {
        let routes = root().POST.path("up").readBody { (_, c) -> String in
            if case .other(let b) = c { return "\(b.count)" }
            return "none"
        }.text()
        try await Server(routes: routes, port: 0, idleTimeout: .seconds(2)).withServer { port in
            let parts = [rawHead("POST", "/up", [("Content-Length", "6"), ("Connection", "close")])]
                + (0..<6).map { _ in Array("x".utf8) }
            let r = await rawHTTP(port: port, parts, timeout: 20, partDelay: 0.5)
            #expect(r.status == 200)
            #expect(r.body == "6")
        }
    }

    /// A client that sends a request to a slow route and then closes its side (a disconnect)
    /// used to keep the server's socket open until the route finished: the response was
    /// pending and the channel writable, so it never counted as idle (the review saw 50
    /// sockets in CLOSE_WAIT). After the client's FIN, nothing written for the timeout closes it.
    @Test func disconnectedClientIsReleasedWhileTheRouteRuns() async throws {
        let routes = root().path("hang").map { () async throws -> String in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return "late"
        }.text()
        try await Server(routes: routes, port: 0, idleTimeout: .seconds(1)).withServer { port in
            // FIN with the request, and FIN arriving on its own after the request was read
            // (on macOS NIO doesn't read further while a response is pending, so the FIN was
            // never seen there and the socket stayed in CLOSE_WAIT).
            for delay in [0, 0.5] {
                let r = await rawHTTP(port: port, [rawHead("GET", "/hang")], timeout: 20, halfClose: true,
                                      halfCloseDelay: delay)
                #expect(r.closed, "FIN after \(delay) s")
                #expect(r.elapsed < 10, "FIN after \(delay) s: the connection stayed open for \(r.elapsed) s")
            }
        }
    }

    /// A client that stops reading a large response is still timed out: its writes back up and
    /// none completes.
    @Test func clientThatStopsReadingIsClosed() async throws {
        let size = 64 * 1024 * 1024
        let routes = root().path("big").map { BytesOutput(body: Array(repeating: 0x61, count: size)) as HTTPOutput }
        try await Server(routes: routes, port: 0, idleTimeout: .milliseconds(300)).withServer { port in
            let r = await rawHTTP(port: port, [rawHead("GET", "/big", [("Connection", "close")])], timeout: 5, readDelay: 3)
            #expect(r.text.utf8.count < size)
            #expect(r.closed)
        }
    }

    /// A request the HTTP parser rejects gets NIO's 400; the connection must then close
    /// rather than stay open with a parser that will never accept another request.
    @Test func connectionClosesAfterAParseError() async throws {
        try await Server(routes: tenBytes, port: 0, idleTimeout: nil).withServer { port in
            let r = await rawHTTP(port: port, [raw("GARBAGE\r\n\r\n")], timeout: 20)
            #expect(r.status == 400)
            #expect(r.closed)
            #expect(r.elapsed < 10)
        }
    }

    @Test func webSocketIsNotClosedByTheHTTPIdleTimeout() async throws {
        let routes = root().path("ws").webSocket(protocol: "p") { _ -> WebSocketHandler in
            return { ws in
                while let message = try? await ws.readMessage() {
                    if case .text(let t) = message { try? await ws.writeMessage(.text(t)) }
                    if case .close = message { return }
                }
            }
        }
        try await Server(routes: routes, port: 0, idleTimeout: .seconds(1)).withServer { port in
            let echo = try await withRawWebSocket(port: port, path: "/ws", protocol: "p") { ws in
                Thread.sleep(forTimeInterval: 2.5)
                try ws.sendText("still here")
                return try ws.receiveFrame()
            }
            #expect(echo == .init(opcode: 0x1, payload: Array("still here".utf8)))
        }
    }

    // MARK: Response framing

    /// A response to HEAD has no body (RFC 9110 §9.3.2). The body used to be sent anyway, so a
    /// keep-alive client or proxy read it as the start of the next response.
    @Test func headResponseHasNoBody() async throws {
        try await Server(routes: tenBytes, port: 0).withServer { port in
            let r = await rawHTTP(port: port, [raw("HEAD /ten HTTP/1.1\r\nHost: x\r\n\r\n" +
                                              "GET /ten HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")])
            let responses = r.text.components(separatedBy: "HTTP/1.1 ")
            #expect(responses.count == 3, "\(r.text.debugDescription)")
            // The HEAD response keeps the GET's Content-Length but ends with its head.
            #expect(responses[1].lowercased().contains("content-length: 10"))
            #expect(responses[1].hasSuffix("\r\n\r\n"), "\(responses[1].debugDescription)")
            #expect(responses[2].hasSuffix("0123456789"))
        }
    }

    @Test func noBodyFor204And304() async throws {
        let p = root(path: "/", HTTPRequest.self)
        let routes = try root().dir(
            p.empty.map { BytesOutput(head: HTTPHead(status: .noContent, headers: [:]), body: Array("x".utf8)) as HTTPOutput },
            p.same.map { BytesOutput(head: HTTPHead(status: .notModified, headers: [:]), body: Array("x".utf8)) as HTTPOutput }
        )
        try await Server(routes: routes, port: 0).withServer { port in
            for path in ["/empty", "/same"] {
                let r = await rawHTTP(port: port, [raw("GET \(path) HTTP/1.1\r\nHost: x\r\n\r\n" +
                                                  "GET /ten HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")])
                let first = r.text.components(separatedBy: "HTTP/1.1 ").dropFirst().first ?? ""
                #expect(first.hasSuffix("\r\n\r\n"), "\(path): \(first.debugDescription)")
            }
        }
    }

    /// statusCheck's 2xx status, or one a handler set on the context, survives an output
    /// that sets no status of its own.
    @Test func contextStatusSurvivesAnOutputWithoutAStatus() async throws {
        let routes = root().path("made").map { "made" }.statusCheck { .created }.text()
        try await Server(routes: routes, port: 0).withServer { port in
            let r = await rawHTTP(port: port, [rawHead("GET", "/made", [("Connection", "close")])])
            #expect(r.status == 201)
            #expect(r.body == "made")
        }
    }

    // MARK: Request smuggling and malformed requests (regression coverage; NIO's parser
    // already refuses these)

    @Test("Ambiguous framing is refused with 400 and the connection closed",
          arguments: [
            "POST /ten HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /ten HTTP/1.1\r\nHost: x\r\n\r\n",
            "POST /ten HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello!",
            "POST /ten HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: xchunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
            "POST /ten HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked, identity\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
            "POST /ten HTTP/1.1\r\nHost: x\r\nTransfer-Encoding : chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
            "GET /ten HTTP/1.1\r\nHost: x\r\nX-A: b\r\n c\r\n\r\n",
            "GET /ten HTTP/1.1\nHost: x\n\n",
            "GET /ten HTTP/9.9\r\n\r\n",
            "GET /t\u{0}n HTTP/1.1\r\n\r\n",
            "GET /\u{1F600} HTTP/1.1\r\nHost: x\r\n\r\n",
          ])
    func ambiguousOrMalformedRequestIsRefused(_ request: String) async throws {
        try await Server(routes: tenBytes, port: 0).withServer { port in
            let r = await rawHTTP(port: port, [raw(request)], timeout: 5)
            #expect(r.status == 400, "\(r.text.debugDescription)")
            #expect(r.closed)
            // Nothing after the refused request was served.
            #expect(!r.text.contains("0123456789"))
            // And the server is still serving.
            let next = await rawHTTP(port: port, [rawHead("GET", "/ten", [("Connection", "close")])])
            #expect(next.status == 200)
        }
    }

    @Test func oversizedHeaderIsRefused() async throws {
        try await Server(routes: tenBytes, port: 0).withServer { port in
            let head = "GET /ten HTTP/1.1\r\nHost: x\r\nX-Big: \(String(repeating: "a", count: 200_000))\r\n\r\n"
            let r = await rawHTTP(port: port, [raw(head)], timeout: 5)
            #expect(r.status == 400)
            #expect(r.closed)
        }
    }

    /// A header value the application sets with CR/LF in it must not split the response.
    /// NIO's response header validator refuses the head and the connection is closed.
    @Test func headerValueWithCRLFDoesNotInjectHeaders() async throws {
        let routes = root().path("inject").map {
            TextOutput("x", headers: [("X-Test", "a\r\nSet-Cookie: injected=1")]) as HTTPOutput
        }
        try await Server(routes: routes, port: 0).withServer { port in
            let r = await rawHTTP(port: port, [rawHead("GET", "/inject", [("Connection", "close")])])
            #expect(!r.text.lowercased().contains("set-cookie"), "\(r.text.debugDescription)")
            #expect(r.closed)
        }
    }

    /// A response to HEAD for an output of unknown length (a stream, or anything under
    /// compressed()) used to be framed as chunked and end with the "0\r\n\r\n" terminator, which
    /// a keep-alive client reads as the start of the next response.
    @Test("HEAD on a body of unknown length sends no chunked framing", arguments: ["/stream", "/gz"])
    func headOnStreamingOutput(_ path: String) async throws {
        let routes = try root().dir(
            root().path("stream").map { StreamOutput() as HTTPOutput },
            root().path("gz").map { BytesOutput(body: Array(repeating: 65, count: 20_000)) as HTTPOutput }.compressed(),
            tenBytes
        )
        try await Server(routes: routes, port: 0).withServer { port in
            let r = await rawHTTP(port: port, [raw("HEAD \(path) HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n" +
                                              "GET /ten HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")])
            let responses = r.text.components(separatedBy: "HTTP/1.1 ")
            #expect(responses.count == 3, "\(r.text.debugDescription)")
            #expect(responses[1].hasSuffix("\r\n\r\n"), "\(responses[1].debugDescription)")
            #expect(!responses[1].lowercased().contains("transfer-encoding"))
            #expect(r.text.hasSuffix("0123456789"))
        }
    }

    /// GET of a body of unknown length is chunked on HTTP/1.1 and keeps the connection usable.
    @Test func streamingBodyIsChunkedAndKeepsTheConnection() async throws {
        let routes = try root().dir(root().path("stream").map { StreamOutput() as HTTPOutput }, tenBytes)
        try await Server(routes: routes, port: 0).withServer { port in
            let r = await rawHTTP(port: port, [raw("GET /stream HTTP/1.1\r\nHost: x\r\n\r\n" +
                                              "GET /ten HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")])
            #expect(r.text.lowercased().contains("transfer-encoding: chunked"))
            #expect(r.text.contains("2\r\nab\r\n2\r\ncd\r\n2\r\nef\r\n0\r\n\r\nHTTP/1.1 200"), "\(r.text.debugDescription)")
            #expect(r.text.hasSuffix("0123456789"))
        }
    }

    /// HTTP/1.0 has no chunked encoding: a body of unknown length ends with the connection.
    @Test func streamingBodyOnHTTP10ClosesTheConnection() async throws {
        let routes = root().path("stream").map { StreamOutput() as HTTPOutput }
        try await Server(routes: routes, port: 0).withServer { port in
            let r = await rawHTTP(port: port, [raw("GET /stream HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")], timeout: 20)
            #expect(r.text.hasSuffix("\r\n\r\nabcdef"), "\(r.text.debugDescription)")
            #expect(!r.text.lowercased().contains("transfer-encoding"))
            #expect(!r.text.lowercased().contains("keep-alive"))
            #expect(r.closed)
            #expect(r.elapsed < 10)
        }
    }

    /// Two Host headers are refused (RFC 9112 §3.2); NIO's parser accepts them and the request
    /// used to be served.
    @Test func duplicateHostIsRefused() async throws {
        try await Server(routes: tenBytes, port: 0).withServer { port in
            let r = await rawHTTP(port: port, [raw("GET /ten HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n")], timeout: 20)
            #expect(r.status == 400, "\(r.text.debugDescription)")
            #expect(!r.text.contains("0123456789"))
            #expect(r.closed)
        }
    }

    /// A route whose final status is informational (1xx) used to abort the whole process
    /// (100, 103: a precondition in NIO's protocol error handler) or leave the connection
    /// confused (101). It now gets 500 and the connection is closed.
    @Test("A 1xx final status is refused with 500", arguments: [100, 101, 103])
    func informationalFinalStatus(_ code: Int) async throws {
        let routes = try root().dir(
            root().path("info").map {
                BytesOutput(head: HTTPHead(status: HTTPResponseStatus(statusCode: code), headers: [:]), body: []) as HTTPOutput
            },
            tenBytes
        )
        try await Server(routes: routes, port: 0).withServer { port in
            let r = await rawHTTP(port: port, [rawHead("GET", "/info"), rawHead("GET", "/ten")], timeout: 20)
            #expect(r.status == 500, "\(r.text.debugDescription)")
            #expect(r.closed)
            #expect(!r.text.contains("0123456789"))
            let next = await rawHTTP(port: port, [rawHead("GET", "/ten", [("Connection", "close")])], timeout: 20)
            #expect(next.status == 200)
        }
    }

    /// An output whose body doesn't match its own Content-Length used to stay keep-alive, so
    /// the next response on the connection was read as part of (or after) this one; duplicate
    /// or invalid Content-Length values went out verbatim.
    @Test func outputContentLengthIsEnforced() async throws {
        let routes = try root().dir(
            root().path("short").map { output("10", body: "12345") },
            root().path("long").map { output("3", body: "0123456789") },
            root().path("dup").map { output("5", "7", body: "abcde") },
            root().path("same").map { output("5", "5", body: "abcde") },
            root().path("bad").map { output("abc", body: "abcde") },
            tenBytes
        )
        try await Server(routes: routes, port: 0).withServer { port in
            for path in ["/short", "/long"] {
                let r = await rawHTTP(port: port, [rawHead("GET", path), rawHead("GET", "/ten")], timeout: 20)
                #expect(r.closed, "\(path)")
                #expect(!r.text.contains("0123456789HTTP") && r.text.components(separatedBy: "HTTP/1.1 ").count == 2,
                        "\(path): \(r.text.debugDescription)")
            }
            for path in ["/dup", "/bad"] {
                let r = await rawHTTP(port: port, [rawHead("GET", path, [("Connection", "close")])], timeout: 20)
                let lengths = r.text.lowercased().components(separatedBy: "\r\n").filter { $0.hasPrefix("content-length:") }
                #expect(lengths.isEmpty, "\(path): \(r.text.debugDescription)")
            }
            let same = await rawHTTP(port: port, [rawHead("GET", "/same"), rawHead("GET", "/ten", [("Connection", "close")])], timeout: 20)
            let lengths = same.text.lowercased().components(separatedBy: "\r\n").filter { $0.hasPrefix("content-length:") }
            #expect(lengths == ["content-length: 5", "content-length: 10"], "\(same.text.debugDescription)")
            #expect(same.text.hasSuffix("0123456789"))
        }
    }
}

@Sendable private func output(_ length: String..., body: String) -> HTTPOutput {
    BytesOutputRaw(headers: length.map { ("Content-Length", $0) }, body: Array(body.utf8))
}

/// An output that sets its headers verbatim, Content-Length included.
private final class BytesOutputRaw: HTTPOutput, @unchecked Sendable {
    let headers: [(String, String)]
    var body: [UInt8]?
    init(headers: [(String, String)], body: [UInt8]) {
        self.headers = headers
        self.body = body
    }
    override func head(request: HTTPRequestInfo) -> HTTPHead? { HTTPHead(headers: HTTPHeaders(headers)) }
    override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
        defer { body = nil }
        return body.map { allocator.buffer(bytes: $0) }
    }
}
