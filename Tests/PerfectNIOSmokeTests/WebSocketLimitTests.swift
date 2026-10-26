//
//  WebSocketLimitTests.swift
//  PerfectNIOSmokeTests
//
//  The WebSocket message size limit (close code 1009) and the keepalive that closes an
//  upgraded connection whose client has gone silent.
//

import Testing
import Foundation
import NIOConcurrencyHelpers
@testable import PerfectNIO

/// Echoes each text or binary message's size as text, and records every message it reads.
private func sizeEchoRoute(_ seen: NIOLockedValueBox<[String]>,
                           options: [WebSocketOption] = []) -> Routes<HTTPRequest, HTTPOutput> {
    root().path("ws").webSocket(protocol: "p", options: options) { _ -> WebSocketHandler in
        return { ws in
            while true {
                let message: WebSocketMessage
                do { message = try await ws.readMessage() } catch { return }
                switch message {
                case .text(let t):
                    seen.withLockedValue { $0.append("text \(t.utf8.count)") }
                    try? await ws.writeMessage(.text("\(t.utf8.count)"))
                case .binary(let b):
                    seen.withLockedValue { $0.append("binary \(b.count)") }
                    try? await ws.writeMessage(.text("\(b.count)"))
                case .close:
                    seen.withLockedValue { $0.append("close") }
                    return
                case .ping:
                    seen.withLockedValue { $0.append("ping") }
                case .pong:
                    seen.withLockedValue { $0.append("pong") }
                }
            }
        }
    }
}

/// Sends `count` frames of `size` bytes as one fragmented binary message.
private func sendFragmented(_ ws: RawWebSocket, size: Int, count: Int) throws {
    let chunk = [UInt8](repeating: 7, count: size)
    for i in 0..<count {
        try ws.sendFrame(opcode: i == 0 ? 0x2 : 0x0, payload: chunk, fin: i == count - 1)
    }
}

/// The close code in a close frame's payload.
private func closeCode(_ frame: RawWebSocket.Frame) -> Int? {
    guard frame.opcode == 0x8, frame.payload.count >= 2 else { return nil }
    return Int(frame.payload[0]) << 8 | Int(frame.payload[1])
}

@Suite("WebSocket limits")
struct WebSocketLimitTests {

    @Test func optionsResolveLimitsAndKeepAlive() {
        #expect(([] as [WebSocketOption]).maxMessageSize(serverLimit: 1000) == 1000)
        #expect(([.maxMessageSize(10)] as [WebSocketOption]).maxMessageSize(serverLimit: 1000) == 10)
        // A route can lower the server's limit, not raise it.
        #expect(([.maxMessageSize(5000)] as [WebSocketOption]).maxMessageSize(serverLimit: 1000) == 1000)
        #expect(([.maxMessageSize(-1)] as [WebSocketOption]).maxMessageSize(serverLimit: 1000) == 0)

        let defaults = ([] as [WebSocketOption]).keepAlive
        #expect(defaults?.interval == .seconds(30))
        #expect(defaults?.timeout == .seconds(30))
        let custom = ([.pingInterval(5), .responseTimeout(0)] as [WebSocketOption]).keepAlive
        #expect(custom?.interval == .seconds(5))
        #expect(custom?.timeout == .seconds(1))
        #expect(([.pingInterval(0)] as [WebSocketOption]).keepAlive == nil)
    }

    /// A message bigger than NIO's old 16 KiB frame cap, sent in one frame as browsers do,
    /// used to be refused with 1009. It's well under the 1 MiB default.
    @Test func defaultLimitAcceptsOneLargeFrame() async throws {
        let seen = NIOLockedValueBox<[String]>([])
        try await Server(routes: sizeEchoRoute(seen), port: 0).withServer { port in
            let reply = try await withRawWebSocket(port: port, path: "/ws", protocol: "p") { ws in
                try ws.sendFrame(opcode: 0x2, payload: [UInt8](repeating: 1, count: 100_000))
                return try ws.receiveFrame()
            }
            #expect(reply == .init(opcode: 0x1, payload: Array("100000".utf8)))
        }
    }

    /// Fragments used to be gathered without any limit: one connection could make the server
    /// hold an arbitrarily large message.
    @Test func fragmentedMessageOverTheRouteLimitIsRefused() async throws {
        let seen = NIOLockedValueBox<[String]>([])
        let routes = sizeEchoRoute(seen, options: [.maxMessageSize(10_000)])
        try await Server(routes: routes, port: 0).withServer { port in
            let replies = try await withRawWebSocket(port: port, path: "/ws", protocol: "p") { ws in
                // Exactly at the limit is fine.
                try sendFragmented(ws, size: 2_500, count: 4)
                let first = try ws.receiveFrame()
                // One more fragment's worth is not.
                try sendFragmented(ws, size: 2_500, count: 5)
                return [first, try ws.receiveFrame()]
            }
            #expect(replies[0] == .init(opcode: 0x1, payload: Array("10000".utf8)))
            #expect(closeCode(replies[1]) == 1009)
        }
        #expect(seen.withLockedValue { $0 } == ["binary 10000", "close"])
    }

    @Test func singleFrameOverTheRouteLimitIsRefused() async throws {
        let seen = NIOLockedValueBox<[String]>([])
        let routes = sizeEchoRoute(seen, options: [.maxMessageSize(1_000)])
        try await Server(routes: routes, port: 0).withServer { port in
            let reply = try await withRawWebSocket(port: port, path: "/ws", protocol: "p") { ws in
                try ws.sendText(String(repeating: "x", count: 1_001))
                return try ws.receiveFrame()
            }
            #expect(closeCode(reply) == 1009)
        }
        #expect(seen.withLockedValue { $0 } == ["close"])
    }

    /// The server's limit applies to routes that don't set one, to single frames (NIO's frame
    /// decoder refuses them) and to fragmented messages.
    @Test(arguments: [true, false])
    func serverLimitApplies(fragmented: Bool) async throws {
        let seen = NIOLockedValueBox<[String]>([])
        let server = Server(routes: sizeEchoRoute(seen, options: [.maxMessageSize(1_000_000)]), port: 0,
                            maxWebSocketMessageSize: 4_096)
        try await server.withServer { port in
            let reply = try await withRawWebSocket(port: port, path: "/ws", protocol: "p") { ws in
                if fragmented {
                    try sendFragmented(ws, size: 2_000, count: 3)
                } else {
                    try ws.sendFrame(opcode: 0x2, payload: [UInt8](repeating: 1, count: 5_000))
                }
                return try ws.receiveFrame()
            }
            #expect(closeCode(reply) == 1009)
        }
    }

    /// NIO traps on a frame limit above UInt32.max; the server clamps it instead.
    @Test func hugeServerLimitIsClamped() async throws {
        let seen = NIOLockedValueBox<[String]>([])
        let server = Server(routes: sizeEchoRoute(seen), port: 0, maxWebSocketMessageSize: .max)
        try await server.withServer { port in
            let reply = try await withRawWebSocket(port: port, path: "/ws", protocol: "p") { ws in
                try ws.sendText("ok")
                return try ws.receiveFrame()
            }
            #expect(reply == .init(opcode: 0x1, payload: Array("2".utf8)))
        }
    }

    /// A client that stops sending is pinged, and closed when it doesn't answer.
    @Test func silentClientIsPingedThenClosed() async throws {
        let seen = NIOLockedValueBox<[String]>([])
        let routes = sizeEchoRoute(seen, options: [.pingInterval(1), .responseTimeout(1)])
        try await Server(routes: routes, port: 0).withServer { port in
            let (ping, closedAfter) = try await withRawWebSocket(port: port, path: "/ws", protocol: "p") { ws in
                let ping = try ws.receiveFrame()
                let start = Date()
                // Don't answer: the server should close the connection.
                let closed = (try? ws.receiveFrame()) == nil
                return (ping, closed ? Date().timeIntervalSince(start) : -1)
            }
            #expect(ping.opcode == 0x9)
            #expect(ping.payload == WebSocketKeepAliveHandler.pingPayload)
            #expect(closedAfter >= 0.9 && closedAfter < 3, "closed after \(closedAfter) s")
        }
        #expect(seen.withLockedValue { $0 } == ["close"])
    }

    /// A client that answers the keepalive stays connected, and the handler never sees the
    /// keepalive's pong.
    @Test func answeringClientStaysOpen() async throws {
        let seen = NIOLockedValueBox<[String]>([])
        let routes = sizeEchoRoute(seen, options: [.pingInterval(1), .responseTimeout(1)])
        try await Server(routes: routes, port: 0).withServer { port in
            let reply = try await withRawWebSocket(port: port, path: "/ws", protocol: "p") { ws in
                for _ in 0..<3 {
                    let ping = try ws.receiveFrame()
                    guard ping.opcode == 0x9 else { throw RawWebSocketError("expected a ping, got \(ping.opcode)") }
                    try ws.sendFrame(opcode: 0xA, payload: ping.payload)
                }
                try ws.sendText("still here")
                return try ws.receiveFrame()
            }
            #expect(reply == .init(opcode: 0x1, payload: Array("10".utf8)))
        }
        #expect(seen.withLockedValue { $0 }.first == "text 10")
        #expect(!seen.withLockedValue { $0 }.contains("pong"))
    }

    @Test func keepAliveCanBeTurnedOff() async throws {
        let seen = NIOLockedValueBox<[String]>([])
        let routes = sizeEchoRoute(seen, options: [.pingInterval(0), .responseTimeout(1)])
        try await Server(routes: routes, port: 0).withServer { port in
            let reply = try await withRawWebSocket(port: port, path: "/ws", protocol: "p") { ws in
                Thread.sleep(forTimeInterval: 2.5)
                try ws.sendText("hello")
                return try ws.receiveFrame()
            }
            #expect(reply == .init(opcode: 0x1, payload: Array("5".utf8)))
        }
    }
}
