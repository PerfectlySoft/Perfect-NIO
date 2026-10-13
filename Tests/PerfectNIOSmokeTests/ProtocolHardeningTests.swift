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
            let r = await rawHTTP(port: port, bytes.isEmpty ? [] : [raw(bytes)], timeout: 5)
            #expect(r.closed, "\(name): the server never closed the connection")
            #expect(r.elapsed < 4, "\(name)")
        }
    }

    /// A request the HTTP parser rejects gets NIO's 400; the connection must then close
    /// rather than stay open with a parser that will never accept another request.
    @Test func connectionClosesAfterAParseError() async throws {
        try await Server(routes: tenBytes, port: 0, idleTimeout: nil).withServer { port in
            let r = await rawHTTP(port: port, [raw("GARBAGE\r\n\r\n")], timeout: 5)
            #expect(r.status == 400)
            #expect(r.closed)
            #expect(r.elapsed < 4)
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
        try await Server(routes: routes, port: 0, idleTimeout: .milliseconds(300)).withServer { port in
            let echo = try await withRawWebSocket(port: port, path: "/ws", protocol: "p") { ws in
                Thread.sleep(forTimeInterval: 1)
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
}
