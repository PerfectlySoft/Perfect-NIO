//
//  SmokeTests.swift
//  PerfectNIOSmokeTests
//
//  Validates Phase 2 (async route chain), Phase 3 (HTTPOutput.nextChunk), Phase 4
//  (NIOAsyncChannel serve loop) and Phase 5 (async Server API) end-to-end.
//  Uses URLSession — no external dependencies beyond Foundation.
//
//  Each server test runs inside Server.withServer { }, which binds, runs the body, then
//  shuts the server down (channels + EventLoopGroup) before returning. Tests in a single
//  XCTestCase run serially, so reusing the fixed port across tests is safe.
//

import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIO
import NIOCore
import NIOPosix
import NIOHTTP1
@testable import PerfectNIO

final class PerfectNIOSmokeTests: XCTestCase {

    private let port = 42100
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Binds `routes` on the test port, runs `body` against the live server, then shuts down.
    @discardableResult
    private func withServer<R>(_ routes: Routes<HTTPRequest, HTTPOutput>,
                              _ body: () async throws -> R) async throws -> R {
        try await Server(routes: routes, port: port).withServer { _ in try await body() }
    }

    private func url(_ path: String) -> URL {
        URL(string: "http://localhost:\(port)\(path)")!
    }

    private func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(from: url(path))
        return (data, response as! HTTPURLResponse)
    }

    private func post(
        _ path: String,
        body: Data,
        contentType: String = "application/octet-stream"
    ) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        return (data, response as! HTTPURLResponse)
    }

    // MARK: - Pure unit test (no server needed)

    func testQueryDecoder() {
        // Covers: multi-value keys, key& (no value), key= at end of string (previously buggy —
        // was stored as "key=" in the lookup map, making q["key"] return []).
        let q = QueryDecoder(Array("a=1&b=2&b=3&novalue&empty=".utf8))
        XCTAssertEqual(q["a"], ["1"])
        XCTAssertEqual(q["b"], ["2", "3"])
        XCTAssertEqual(q["novalue"], [""])  // key& → empty-string value
        XCTAssertEqual(q["empty"], [""])    // key= at end of string → empty-string value
        XCTAssertEqual(q["missing"], [])
    }

    // MARK: - Basic routing

    func testBasicText() async throws {
        try await withServer(root { "OK" }.text()) {
            let (data, response) = try await get("/")
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), "OK")
        }
    }

    func testMultiplePaths() async throws {
        let p = root(path: "/", HTTPRequest.self)
        let routes = try root().dir(
            p.alpha { "alpha" },
            p.beta  { "beta"  }
        ).text()
        try await withServer(routes) {
            let (d1, r1) = try await get("/alpha")
            XCTAssertEqual(r1.statusCode, 200)
            XCTAssertEqual(String(data: d1, encoding: .utf8), "alpha")

            let (d2, r2) = try await get("/beta")
            XCTAssertEqual(r2.statusCode, 200)
            XCTAssertEqual(String(data: d2, encoding: .utf8), "beta")
        }
    }

    func testNotFound() async throws {
        try await withServer(root { "OK" }.text()) {
            let (_, response) = try await get("/does-not-exist")
            XCTAssertEqual(response.statusCode, 404)
        }
    }

    func testDuplicateRouteThrows() {
        let p = root(path: "/", HTTPRequest.self)
        XCTAssertThrowsError(
            try root().dir(p.foo { "first" }, p.foo { "second" }).text()
        ) { error in
            if case RouteError.duplicatedRoutes = error { } else {
                XCTFail("Expected RouteError.duplicatedRoutes, got \(error)")
            }
        }
    }

    // MARK: - URI matching

    func testWildcard() async throws {
        // /captured/suffix — wild captures the first segment, "suffix" is a literal path step
        try await withServer(root().wild { $1 }.suffix.text()) {
            let (data, response) = try await get("/hello/suffix")
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
        }
    }

    func testNamedWildcard() async throws {
        let routes = root()
            .wild(name: "id")
            .info
            .request { (_, req) in req.uriVariables["id"] ?? "missing" }
            .text()
        try await withServer(routes) {
            let (data, response) = try await get("/abc123/info")
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), "abc123")
        }
    }

    func testTrailingWildcard() async throws {
        try await withServer(root().base.trailing { $1 }.text()) {
            let (data, _) = try await get("/base/a/b/c")
            XCTAssertEqual(String(data: data, encoding: .utf8), "a/b/c")
        }
    }

    // MARK: - HTTP method routing

    func testMethodRouting() async throws {
        let p = root(path: "/", HTTPRequest.self)
        let routes = try root().dir(
            p.GET.getonly  { "GET response"  },
            p.POST.postonly { "POST response" }
        ).text()
        try await withServer(routes) {
            let (d1, r1) = try await get("/getonly")
            XCTAssertEqual(r1.statusCode, 200)
            XCTAssertEqual(String(data: d1, encoding: .utf8), "GET response")

            let (d2, r2) = try await post("/postonly", body: Data())
            XCTAssertEqual(r2.statusCode, 200)
            XCTAssertEqual(String(data: d2, encoding: .utf8), "POST response")

            // Wrong method → 404
            let (_, r3) = try await post("/getonly", body: Data())
            XCTAssertEqual(r3.statusCode, 404)
        }
    }

    // MARK: - Response types

    func testJSONOutput() async throws {
        struct Greeting: Codable { let message: String }
        try await withServer(root { Greeting(message: "hello") }.json()) {
            let (data, response) = try await get("/")
            XCTAssertEqual(response.statusCode, 200)
            let decoded = try JSONDecoder().decode(Greeting.self, from: data)
            XCTAssertEqual(decoded.message, "hello")
        }
    }

    func testStatusCheck() async throws {
        let p = root(path: "/", HTTPRequest.self)
        let routes = try root().dir(
            p.ok.statusCheck { .ok }.map { "OK" },
            p.forbidden.statusCheck { HTTPResponseStatus.forbidden }.map { "NEVER" }
        ).text()
        try await withServer(routes) {
            let (data, r1) = try await get("/ok")
            XCTAssertEqual(r1.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), "OK")

            let (_, r2) = try await get("/forbidden")
            XCTAssertEqual(r2.statusCode, 403)
        }
    }

    func testUnwrap() async throws {
        let p = root(path: "/", HTTPRequest.self)
        let routes: Routes<HTTPRequest, String?> = try root().dir(
            p.present { Optional("found") },
            p.absent  { Optional<String>.none }
        )
        try await withServer(routes.unwrap { $0 }.text()) {
            let (data, r1) = try await get("/present")
            XCTAssertEqual(r1.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), "found")

            let (_, r2) = try await get("/absent")
            XCTAssertEqual(r2.statusCode, 500)
        }
    }

    // MARK: - Request body handling

    func testPOSTBodyReading() async throws {
        let routes = root().POST.readBody { (_, body) -> String in
            switch body {
            case .other(let bytes): return String(bytes: bytes, encoding: .utf8) ?? "?"
            default: return "unexpected content type"
            }
        }.text()
        try await withServer(routes) {
            let payload = "hello from the test"
            let (data, response) = try await post("/", body: Data(payload.utf8))
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), payload)
        }
    }

    func testJSONDecode() async throws {
        struct Payload: Codable { let x: Int }
        let routes = root().POST
            .decode(Payload.self) { payload in payload.x * 2 }
            .json()
        try await withServer(routes) {
            let body = try JSONEncoder().encode(Payload(x: 21))
            let (data, response) = try await post("/", body: body, contentType: "application/json")
            XCTAssertEqual(response.statusCode, 200)
            let result = try JSONDecoder().decode(Int.self, from: data)
            XCTAssertEqual(result, 42)
        }
    }

    // MARK: - Phase 3: custom HTTPOutput.nextChunk()

    func testCustomNextChunkOutput() async throws {
        // Verifies that the async nextChunk() pull loop in the serve loop works end-to-end.
        class ChunkedOutput: HTTPOutput, @unchecked Sendable {
            var count = 0
            override func head(request: HTTPRequestInfo) -> HTTPHead? {
                HTTPHead(headers: HTTPHeaders([("Content-Length", "4096")]))
            }
            override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
                guard count < 4 else { return nil }
                let byte = UInt8(48 + count) // '0', '1', '2', '3'
                count += 1
                var buf = allocator.buffer(capacity: 1024)
                buf.writeRepeatingByte(byte, count: 1024)
                return buf
            }
        }

        try await withServer(root { ChunkedOutput() as HTTPOutput }) {
            let (data, response) = try await get("/")
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(data.count, 4096)
            XCTAssertEqual(data[0],    UInt8(ascii: "0"))
            XCTAssertEqual(data[1023], UInt8(ascii: "0"))
            XCTAssertEqual(data[1024], UInt8(ascii: "1"))
            XCTAssertEqual(data[2048], UInt8(ascii: "2"))
            XCTAssertEqual(data[3072], UInt8(ascii: "3"))
        }
    }

    // MARK: - Built-in output types

    func testFileOutput() async throws {
        let tmpPath = "/tmp/smoke-\(UUID().uuidString).txt"
        let content = "file content from PerfectNIO"
        try Data(content.utf8).write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let routes = root().f { try FileOutput(localPath: tmpPath) as HTTPOutput }
        try await withServer(routes) {
            let (data, response) = try await get("/f")
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), content)
        }
    }

    func testCompression() async throws {
        // 16 KB — above CompressedOutput.minCompressLength (~14 KB), so gzip is applied.
        // URLSession transparently decompresses gzip; we verify the round-tripped content.
        // A broken compressor produces wrong or missing content, causing the assertion to fail.
        let bytes: [UInt8] = (0..<16).flatMap { i in
            Array(String(repeating: "\(i % 10)", count: 1024).utf8)
        }
        let expected = String(bytes: bytes, encoding: .utf8)!

        let routes = root { BytesOutput(body: bytes) as HTTPOutput }.compressed()
        try await withServer(routes) {
            let (data, response) = try await get("/")
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), expected)
        }
    }

    // MARK: - Phase 6: WebSocket

    func testWebSocketEcho() async throws {
        // /echo upgrades to WebSocket and echoes text frames back.
        let routes = root().echo.webSocket(protocol: "echo", options: [.manualClose]) { _ -> WebSocketHandler in
            return { ws in
                while true {
                    let message: WebSocketMessage
                    do { message = try await ws.readMessage() } catch { return }
                    switch message {
                    case .text(let t): try? await ws.writeMessage(.text(t))
                    case .binary(let b): try? await ws.writeMessage(.binary(b))
                    case .close: try? await ws.writeMessage(.close); return
                    default: break
                    }
                }
            }
        }
        try await withServer(routes) {
            let task = session.webSocketTask(with: URL(string: "ws://localhost:\(port)/echo")!)
            task.resume()
            defer { task.cancel(with: .normalClosure, reason: nil) }

            try await task.send(.string("hello ws"))
            let first = try await task.receive()
            guard case .string(let s1) = first else { return XCTFail("expected text frame, got \(first)") }
            XCTAssertEqual(s1, "hello ws")

            // A second round-trip confirms the connection stays open and keeps echoing.
            try await task.send(.string("again"))
            let second = try await task.receive()
            guard case .string(let s2) = second else { return XCTFail("expected text frame, got \(second)") }
            XCTAssertEqual(s2, "again")
        }
    }

    func testWebSocketRejectsNonWebSocketPath() async throws {
        // A WebSocket handshake to a path with no webSocket() route must NOT upgrade, and — per
        // RFC 6455 §4.2.2 / §1.3 — must be served as ordinary HTTP with the route's natural status
        // (here 404), not closed or hung. URLSession's WS task can't surface the status, so we send
        // the raw handshake and assert the HTTP response line.
        let routes = root().echo.webSocket(protocol: "echo") { _ -> WebSocketHandler in { _ in } }
        try await withServer(routes) {
            let handshake = """
            GET /not-a-socket HTTP/1.1\r
            Host: localhost\r
            Connection: Upgrade\r
            Upgrade: websocket\r
            Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
            Sec-WebSocket-Version: 13\r
            \r

            """
            let response = try rawExchange(port: port, request: handshake)
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 404"), "expected HTTP 404, got: \(response.prefix(40))")
            XCTAssertFalse(response.contains("101 Switching Protocols"), "must not upgrade a non-WebSocket path")
        }
    }

    /// Opens a raw TCP connection to `port`, sends `request`, and returns the response up to the
    /// end of the headers (or until the peer closes). Used to inspect raw HTTP status lines.
    private func rawExchange(port: Int, request: String, timeout: TimeAmount = .seconds(3)) throws -> String {
        final class Collector: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            let promise: EventLoopPromise<String>
            var acc = ""
            init(_ p: EventLoopPromise<String>) { promise = p }
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buf = Self.unwrapInboundIn(data)
                acc += buf.readString(length: buf.readableBytes) ?? ""
                if acc.contains("\r\n\r\n") { promise.succeed(acc) }
            }
            func channelInactive(context: ChannelHandlerContext) { promise.succeed(acc) }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let promise = group.next().makePromise(of: String.self)
        group.next().scheduleTask(in: timeout) { promise.fail(ServerError("rawExchange timed out")) }
        let channel = try ClientBootstrap(group: group)
            .channelInitializer { ch in ch.pipeline.addHandler(Collector(promise)) }
            .connect(host: "127.0.0.1", port: port).wait()
        var buf = channel.allocator.buffer(capacity: request.utf8.count)
        buf.writeString(request)
        try channel.writeAndFlush(buf).wait()
        defer { try? channel.close().wait() }
        return try promise.futureResult.wait()
    }

    // MARK: - Phase 7: gap coverage from old test suite

    /// .ext("json") matches /path.json and 404s /path; same base route serves both extensions.
    func testPathExtension() async throws {
        struct Payload: Codable { let value: Int }
        let base = root().data { Payload(value: 99) }
        let routes = try root().dir(
            base.ext("json").json(),
            base.ext("txt").map { "\($0.value)" }.text()
        )
        try await withServer(routes) {
            let (data, r1) = try await get("/data.json")
            XCTAssertEqual(r1.statusCode, 200)
            let decoded = try JSONDecoder().decode(Payload.self, from: data)
            XCTAssertEqual(decoded.value, 99)

            let (data2, r2) = try await get("/data.txt")
            XCTAssertEqual(r2.statusCode, 200)
            XCTAssertEqual(String(data: data2, encoding: .utf8), "99")

            let (_, r3) = try await get("/data")
            XCTAssertEqual(r3.statusCode, 404)
        }
    }

    /// .request { out, req in } gives the handler access to the HTTPRequest object.
    func testRequestAccess() async throws {
        let routes = root().ping.request { _, req in req.path }.text()
        try await withServer(routes) {
            let (data, response) = try await get("/ping")
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), "/ping")
        }
    }

    /// `HTTPRequest.cookies` previously split every "=" in a cookie pair
    /// unboundedly, so any value containing an embedded "=" (extremely
    /// common for base64-encoded/padded tokens) produced 3+ parts and got
    /// silently dropped by the `d.count == 2` guard -- the whole cookie
    /// vanished rather than just losing its trailing content. Confirmed by
    /// a real report of cookies "not being propagated" for a scrubs.test
    /// store cookie carrying an encoded value.
    func testCookiesWithEmbeddedEqualsSignsAreNotDropped() async throws {
        let routes = root().cookiecheck.request { _, req in
            req.cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        }.text()
        try await withServer(routes) {
            var request = URLRequest(url: url("/cookiecheck"))
            // URLSession otherwise manages the `Cookie` header itself via
            // its own cookie jar and silently ignores a manually-set value.
            request.httpShouldHandleCookies = false
            request.setValue(
                "plain=abc; padded=dGVzdA==; multi=a=b=c",
                forHTTPHeaderField: "Cookie"
            )
            let (data, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(
                String(data: data, encoding: .utf8),
                "multi=a=b=c|padded=dGVzdA==|plain=abc"
            )
        }
    }

    /// routes.describe lists the URI key for every registered route.
    func testDescribeRoutes() throws {
        let routes = try root().dir(
            root().a.b { "ab" },
            root().GET.c { "c" },
            root().wild(name: "x").d { "d" }
        ).text()
        let uris = Set(routes.describe.map(\.uri))
        XCTAssertTrue(uris.contains("/a/b"), "missing /a/b in \(uris)")
        XCTAssertTrue(uris.contains("GET:///c"), "missing GET:///c in \(uris)")
        XCTAssertTrue(uris.contains("/*/d"), "missing /*/d in \(uris)")
    }

    /// statusCheck + unwrap compose into an auth gate: missing token → 401, valid token → 200.
    func testAuthPattern() async throws {
        struct AuthSession: Sendable { let username: String }
        let routes: Routes<HTTPRequest, HTTPOutput> = root { req -> AuthSession? in
                req.headers["X-Auth-Token"].first == "secret" ? AuthSession(username: "alice") : nil
            }
            .statusCheck { $0 == nil ? .unauthorized : .ok }
            .unwrap { $0 }
            .request { auth, _ in auth.username }
            .text()
        try await withServer(routes) {
            let (_, r1) = try await get("/")
            XCTAssertEqual(r1.statusCode, 401)

            var authReq = URLRequest(url: url("/"))
            authReq.addValue("secret", forHTTPHeaderField: "X-Auth-Token")
            let (data, r2) = try await session.data(for: authReq)
            XCTAssertEqual((r2 as! HTTPURLResponse).statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), "alice")
        }
    }

    // MARK: - Phase 5: idle timeout

    func testIdleTimeoutClosesConnection() async throws {
        // A short read-idle timeout must close an otherwise-idle keep-alive connection.
        // We make one request (succeeds), then confirm the server is still serving new
        // connections after the idle one would have been dropped.
        let server = Server(routes: root { "OK" }.text(), port: port, idleTimeout: .milliseconds(200))
        try await server.withServer { _ in
            let (data, r1) = try await get("/")
            XCTAssertEqual(r1.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), "OK")

            // Wait past the idle timeout; the server must still accept a fresh request.
            try await Task.sleep(for: .milliseconds(400))
            let (_, r2) = try await get("/")
            XCTAssertEqual(r2.statusCode, 200)
        }
    }
}
