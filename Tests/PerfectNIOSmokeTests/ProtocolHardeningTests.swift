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
}
