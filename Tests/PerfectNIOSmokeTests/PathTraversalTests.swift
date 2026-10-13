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
        // A fragment is never sent by a conforming client, and routing doesn't cut at "#".
        "/files/x#/../../secret.txt", "/files/x%23/../y", "/files/x#y", "/files/#",
        // "..;" and "..%00" aren't ".." to the filesystem, but are refused anyway.
        "/files/..;/x", "/files/..;jsessionid=1/x", "/files/..%00/x",
        "/files/%25252525252e%25252525252e/x",
        "http://evil/files/../x",
    ]
    static let allowed = ["/files/a..b", "/files/.hidden", "/files/x.txt", "/files/a.b.c/d", "/files/...", "/files/x?q=..%2f",
                          // Not dots to any filesystem: overlong UTF-8, %u escapes, fullwidth full stops.
                          "/files/%c0%ae%c0%ae/x", "/files/%u002e%u002e/x", "/files/%EF%BC%8E%EF%BC%8E/x"]

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
        for path in Self.refused where !path.contains("#") && !path.contains("%23") {
            #expect(RequestPath.hasDotDotSegment(path), "\(path)")
        }
        for path in Self.allowed { #expect(!RequestPath.hasDotDotSegment(path), "\(path)") }
        #expect(!RequestPath.hasDotDotSegment("/a/%zz/b"))
        #expect(RequestPath.hasDotDotSegment("/a/%zz/%2e%2e"))
    }

    /// Decoding until stable stripped one "%25" layer per pass and was quadratic: an 80 KB URI
    /// of nested encodings cost seconds of CPU (30 of them stalled other connections). Decoding
    /// is now capped at a few passes, and a path still changing after them is refused.
    @Test func nestedEncodingIsBoundedAndRefused() {
        func path(_ layers: Int) -> String { "/seg/%" + String(repeating: "25", count: layers) + "2e%2e/x" }
        // Linear, not quadratic: four times the input may take about four times as long, not
        // sixteen. (Relative timing, best of three, so a slow or loaded machine, or Guard
        // Malloc, doesn't matter.)
        func seconds(_ layers: Int) -> Double {
            let input = path(layers)
            return (0..<3).map { _ in
                let start = Date()
                #expect(RequestPath.hasDotDotSegment(input))
                return Date().timeIntervalSince(start)
            }.min()!
        }
        let small = seconds(8_000), large = seconds(32_000)
        #expect(large < small * 8 + 0.05, "\(small) s for 16 KB, \(large) s for 64 KB")
        // Nine layers is past the cap: refused even though it isn't (yet) a "..".
        #expect(RequestPath.hasDotDotSegment("/seg/%" + String(repeating: "25", count: 9) + "41/x"))
        // Two layers decodes to "A": fine.
        #expect(!RequestPath.hasDotDotSegment("/seg/%252541/x"))
    }

    @Test func overlongRequestTargetIs414() async throws {
        let routes = root().path("seg").trailing { (_: HTTPRequest, rest: String) in rest }.text()
        try await Server(routes: routes, port: 0).withServer { port in
            let long = "/seg/%" + String(repeating: "25", count: 40_000) + "2e%2e/x"
            let start = Date()
            let r = await rawHTTP(port: port, [raw("GET \(long) HTTP/1.1\r\nHost: x\r\n\r\n")], timeout: 20)
            #expect(r.status == 414, "\(r.text.prefix(80).debugDescription)")
            #expect(r.closed)
            #expect(Date().timeIntervalSince(start) < 5)
            let ok = await rawHTTP(port: port, [raw("GET /seg/" + String(repeating: "a", count: 8000) + " HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")], timeout: 20)
            #expect(ok.status == 200)
        }
    }
}
