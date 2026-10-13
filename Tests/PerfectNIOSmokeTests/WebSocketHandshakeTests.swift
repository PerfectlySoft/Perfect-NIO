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

    /// A webSocket route whose pipeline throws during the handshake (an auth check, a
    /// statusCheck) used to run once to resolve the handshake and again, as plain HTTP, to
    /// build the error response.
    @Test func refusedHandshakeRunsThePipelineOnce() async throws {
        let runs = NIOLockedValueBox(0)
        let routes = root().path("ws")
            .statusCheck { () -> HTTPResponseStatus in
                runs.withLockedValue { $0 += 1 }
                return .forbidden
            }
            .webSocket(protocol: "p") { _ -> WebSocketHandler in { _ in } }
        try await Server(routes: routes, port: 0).withServer { port in
            let r = await rawHTTP(port: port, [handshake("/ws")], timeout: 10)
            #expect(r.status == 403, "\(r.text.debugDescription)")
            #expect(!r.text.contains("101 Switching"))
            #expect(runs.withLockedValue { $0 } == 1)
        }
    }

    @Test func throwingHandshakeCallbackRunsOnce() async throws {
        let runs = NIOLockedValueBox(0)
        let routes = root().path("ws").webSocket(protocol: "p") { _ -> WebSocketHandler in
            runs.withLockedValue { $0 += 1 }
            throw ErrorOutput(status: .unauthorized, description: "no")
        }
        try await Server(routes: routes, port: 0).withServer { port in
            let r = await rawHTTP(port: port, [handshake("/ws")], timeout: 10)
            #expect(r.status == 401)
            #expect(r.body == "no")
            #expect(runs.withLockedValue { $0 } == 1)
        }
    }

    /// A parent flagged as a WebSocket endpoint (webSocket composed with dir) whose child is
    /// plain HTTP: the handshake isn't upgraded and the child's output is served, from a
    /// single run.
    @Test func flaggedParentWithPlainChildRunsOnce() async throws {
        let runs = NIOLockedValueBox(0)
        let child = root(path: "/", HTTPOutput.self).path("plain").map { _ -> HTTPOutput in
            runs.withLockedValue { $0 += 1 }
            return TextOutput("plain")
        }
        let routes = try root().path("ws").webSocket(protocol: "p") { _ -> WebSocketHandler in { _ in } }
            .dir(child)
        try await Server(routes: routes, port: 0).withServer { port in
            let r = await rawHTTP(port: port, [handshake("/ws/plain", extra: "Connection: close\r\n")], timeout: 10)
            #expect(r.status == 200, "\(r.text.debugDescription)")
            #expect(r.body == "plain")
            #expect(runs.withLockedValue { $0 } == 1)
        }
    }

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
            let r = await rawHTTP(port: port, [handshake(path)], timeout: 20)
            #expect(r.status != 101)
            #expect(r.text.lowercased().contains("connection: close"), "\(r.text.debugDescription)")
            #expect(r.closed)
            #expect(r.elapsed < 10)
        }
    }

    /// webSocket(protocol:) names the subprotocol the endpoint speaks. When the client offers
    /// it, the 101 must select it: browsers fail the connection if they offered subprotocols
    /// and the response names none. The protocol used to be ignored.
    @Test func subprotocolIsSelectedWhenOffered() async throws {
        let routes = root().path("ws").webSocket(protocol: "echo") { _ -> WebSocketHandler in { _ in } }
        try await Server(routes: routes, port: 0).withServer { port in
            func selected(_ offered: String?) async -> String? {
                let r = await rawHTTP(port: port, [handshake("/ws", protocols: offered)], timeout: 5)
                guard r.status == 101 else { return "status \(r.status ?? 0)" }
                return r.text.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("sec-websocket-protocol:") }
                    .map { $0.dropFirst("sec-websocket-protocol:".count).trimmingCharacters(in: .whitespaces) }
            }
            #expect(await selected("echo") == "echo")
            #expect(await selected("chat, echo") == "echo")
            #expect(await selected(nil) == nil)
            // Not offered: the upgrade goes ahead without one, as before; the client decides.
            #expect(await selected("chat") == nil)
        }
    }

    /// A handshake NIO's upgrader would reject (no key, wrong version) used to get the
    /// connection closed with no response. It is now served as HTTP: the webSocket route
    /// answers 426 Upgrade Required with Sec-WebSocket-Version: 13, other routes as usual.
    @Test("A malformed handshake gets an HTTP answer", arguments: [
        ("/ws", "Sec-WebSocket-Version: 8\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n", 426),
        ("/ws", "Sec-WebSocket-Version: 13\r\n", 426),
        ("/missing", "Sec-WebSocket-Version: 8\r\n", 404),
    ])
    func malformedHandshake(_ path: String, _ fields: String, _ status: Int) async throws {
        let routes = root().path("ws").webSocket(protocol: "p") { _ -> WebSocketHandler in { _ in } }
        try await Server(routes: routes, port: 0).withServer { port in
            let request = "GET \(path) HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\(fields)\r\n"
            let r = await rawHTTP(port: port, [Array(request.utf8)], timeout: 20)
            #expect(r.status == status, "\(r.text.debugDescription)")
            if status == 426 {
                #expect(r.text.lowercased().contains("sec-websocket-version: 13"))
            }
            #expect(r.closed)
        }
    }

    /// An Upgrade to another protocol (h2c, anything) used to get an empty reply: NIO's
    /// upgrader closed the connection. The offer is now ignored and the request served.
    @Test("A non-WebSocket Upgrade is served as plain HTTP", arguments: ["h2c", "foo", "TLS/1.2"])
    func otherUpgradeIsIgnored(_ proto: String) async throws {
        let routes = root().path("ten").map { BytesOutput(body: Array("0123456789".utf8)) as HTTPOutput }
        try await Server(routes: routes, port: 0).withServer { port in
            let request = "GET /ten HTTP/1.1\r\nHost: x\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: \(proto)\r\n" +
                "HTTP2-Settings: AAMAAABkAARAAAAAAAIAAAAA\r\n\r\n"
            let r = await rawHTTP(port: port, [Array(request.utf8)], timeout: 20)
            #expect(r.status == 200, "\(r.text.debugDescription)")
            #expect(r.text.hasSuffix("0123456789"))
            #expect(r.closed)
        }
    }
}
