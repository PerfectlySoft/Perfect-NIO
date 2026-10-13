//
//  WebSocketHandshakeTests.swift
//  PerfectNIOSmokeTests
//
//  How many times a webSocket(...) route's pipeline runs for a handshake, and what the
//  client gets back when the pipeline refuses it or isn't a WebSocket endpoint after all.
//

import Testing
import Foundation
import NIOConcurrencyHelpers
@testable import PerfectNIO

private func handshake(_ path: String, protocols: String? = nil, extra: String = "") -> [UInt8] {
    var s = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
    s += "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
    if let protocols { s += "Sec-WebSocket-Protocol: \(protocols)\r\n" }
    s += extra + "\r\n"
    return Array(s.utf8)
}

@Suite("WebSocket handshake")
struct WebSocketHandshakeTests {

    /// NIO's HTTP decoder stops parsing after any request that asks to upgrade, upgraded or
    /// not, so the connection can't carry another request. The response says so and the
    /// connection is closed; it used to stay open and silently drop the next request.
    @Test("A handshake that isn't upgraded ends the connection", arguments: ["/ws", "/ten", "/missing"])
    func handshakeNotUpgradedClosesTheConnection(_ path: String) async throws {
        let routes = try root().dir(
            root().path("ws").statusCheck { .forbidden }.webSocket(protocol: "p") { _ -> WebSocketHandler in { _ in } },
            root().path("ten").map { BytesOutput(body: Array("0123456789".utf8)) as HTTPOutput }
        )
        try await Server(routes: routes, port: 0, idleTimeout: nil).withServer { port in
            let r = await rawHTTP(port: port, [handshake(path)], timeout: 3)
            #expect(r.status != 101)
            #expect(r.text.lowercased().contains("connection: close"), "\(r.text.debugDescription)")
            #expect(r.closed)
            #expect(r.elapsed < 2)
        }
    }
}
