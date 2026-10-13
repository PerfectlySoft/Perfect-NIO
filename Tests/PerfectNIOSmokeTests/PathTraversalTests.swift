//
//  PathTraversalTests.swift
//  PerfectNIOSmokeTests
//
//  A request whose path has a ".." segment, raw or once decoded, is refused with 400 before
//  routing, so wild/trailing values never carry a traversal segment.
//

import Testing
import Foundation
import NIOConcurrencyHelpers
@testable import PerfectNIO

private func raw(_ s: String) -> [UInt8] { Array(s.utf8) }

@Suite("Path traversal")
struct PathTraversalTests {
    static let refused = [
        "/files/../secret.txt", "/files/..", "/..", "/files/a/../../x",
        "/files/%2e%2e/secret.txt", "/files/%2E%2e/x", "/files/.%2e/x", "/files/%2e./x",
        "/files/..%2fsecret.txt", "/files/..%2Fx", "/files/%2e%2e%2fx", "/files/..%5cx",
        "/files/..\\x", "/files/a\\..\\x", "/files/%252e%252e/x",
        "/files/../secret.txt?q=1",
    ]
    static let allowed = ["/files/a..b", "/files/.hidden", "/files/x.txt", "/files/a.b.c/d", "/files/...", "/files/x?q=..%2f"]

    @Test("A .. segment is refused before routing", arguments: refused)
    func refusedPath(_ path: String) async throws {
        let calls = NIOLockedValueBox<[String]>([])
        let routes = root().path("files").trailing { (_: HTTPRequest, rest: String) -> String in
            calls.withLockedValue { $0.append(rest) }
            return rest
        }.text()
        try await Server(routes: routes, port: 0).withServer { port in
            let r = await rawHTTP(port: port, [raw("GET \(path) HTTP/1.1\r\nHost: x\r\n\r\n")], timeout: 20)
            #expect(r.status == 400, "\(path): \(r.text.debugDescription)")
            #expect(r.closed)
            #expect(calls.withLockedValue { $0 }.isEmpty, "\(path) reached the handler")
        }
    }

    @Test("Dots that aren't a .. segment are allowed", arguments: allowed)
    func allowedPath(_ path: String) async throws {
        let routes = root().path("files").trailing { (_: HTTPRequest, rest: String) in rest }.text()
        try await Server(routes: routes, port: 0).withServer { port in
            let r = await rawHTTP(port: port, [raw("GET \(path) HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")], timeout: 20)
            #expect(r.status == 200, "\(path): \(r.text.debugDescription)")
            #expect(!r.body.contains(".."+"/"))
        }
    }

    /// The pre-upgrade router runs a webSocket route's pipeline during the handshake, so the
    /// check has to happen before that too.
    @Test func webSocketHandshakeWithTraversalIsRefused() async throws {
        let runs = NIOLockedValueBox(0)
        let routes = root().path("ws").trailing { (_: HTTPRequest, rest: String) -> String in
            runs.withLockedValue { $0 += 1 }
            return rest
        }.webSocket(protocol: "p") { _ -> WebSocketHandler in { _ in } }
        try await Server(routes: routes, port: 0).withServer { port in
            let request = "GET /ws/%2e%2e/x HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n" +
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
            let r = await rawHTTP(port: port, [raw(request)], timeout: 20)
            #expect(r.status == 400, "\(r.text.debugDescription)")
            #expect(runs.withLockedValue { $0 } == 0)
        }
    }

    @Test func detection() {
        for path in Self.refused { #expect(RequestPath.hasDotDotSegment(path), "\(path)") }
        for path in Self.allowed { #expect(!RequestPath.hasDotDotSegment(path), "\(path)") }
        #expect(!RequestPath.hasDotDotSegment("/a/%zz/b"))
        #expect(RequestPath.hasDotDotSegment("/a/%zz/%2e%2e"))
    }
}
