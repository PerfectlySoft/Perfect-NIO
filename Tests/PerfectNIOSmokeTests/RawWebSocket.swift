//
//  RawWebSocket.swift
//  PerfectNIOSmokeTests
//
//  A minimal blocking WebSocket client (RFC 6455) for tests. URLSessionWebSocketTask
//  can't be used on Linux: swift-corelibs-foundation implements it on libcurl, and
//  Ubuntu's libcurl is built without WebSocket support, so every task fails with
//  NSURLErrorDomain -1002 "WebSockets not supported by libcurl".
//

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct RawWebSocketError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One connection to 127.0.0.1. Every call blocks, so drive it from a thread of its own
/// (see `withRawWebSocket`), never from a task on the server's executor.
final class RawWebSocket {
    struct Frame: Equatable {
        let opcode: UInt8
        let payload: [UInt8]
    }

    private let fd: Int32
    private var pending: [UInt8] = []

    /// Connects and completes the opening handshake for `path`. Throws if the server
    /// doesn't answer 101.
    init(port: Int, path: String, protocol subprotocol: String? = nil, timeout: Int = 5) throws {
        #if canImport(Darwin)
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #else
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw RawWebSocketError("socket() failed: \(errno)") }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw RawWebSocketError("connect() failed: \(errno)")
        }

        var request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        request += "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        request += "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
        if let subprotocol { request += "Sec-WebSocket-Protocol: \(subprotocol)\r\n" }
        request += "\r\n"
        try sendBytes(Array(request.utf8))

        // Read the response head; anything after it is already frame data.
        let terminator: [UInt8] = [13, 10, 13, 10]
        while true {
            if let end = (0...max(0, pending.count - 4)).first(where: { pending.count >= 4 && Array(pending[$0..<($0 + 4)]) == terminator }) {
                let head = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(..<(end + 4))
                guard head.hasPrefix("HTTP/1.1 101") else {
                    close(fd)
                    throw RawWebSocketError("handshake refused: \(head.prefix(60))")
                }
                break
            }
            guard try receiveMore() else {
                close(fd)
                throw RawWebSocketError("connection closed during the handshake")
            }
        }
    }

    deinit { close(fd) }

    /// Sends one final, masked frame (clients must mask, RFC 6455 §5.3).
    func sendFrame(opcode: UInt8, payload: [UInt8]) throws {
        var frame: [UInt8] = [0x80 | opcode]
        switch payload.count {
        case ..<126:
            frame.append(0x80 | UInt8(payload.count))
        case ..<65536:
            frame.append(0x80 | 126)
            frame += [UInt8(payload.count >> 8), UInt8(payload.count & 0xff)]
        default:
            frame.append(0x80 | 127)
            frame += (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xff) }
        }
        let mask: [UInt8] = [0x37, 0xfa, 0x21, 0x3d]
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        try sendBytes(frame)
    }

    func sendText(_ text: String) throws { try sendFrame(opcode: 0x1, payload: Array(text.utf8)) }

    /// Reads the next whole frame (server frames are unmasked). Throws on timeout or EOF.
    func receiveFrame() throws -> Frame {
        try need(2)
        let opcode = pending[0] & 0x0f
        var length = Int(pending[1] & 0x7f)
        var offset = 2
        if length == 126 {
            try need(4)
            length = Int(pending[2]) << 8 | Int(pending[3])
            offset = 4
        } else if length == 127 {
            try need(10)
            length = pending[2..<10].reduce(0) { $0 << 8 | Int($1) }
            offset = 10
        }
        try need(offset + length)
        let payload = Array(pending[offset..<(offset + length)])
        pending.removeSubrange(..<(offset + length))
        return Frame(opcode: opcode, payload: payload)
    }

    private func need(_ count: Int) throws {
        while pending.count < count {
            guard try receiveMore() else { throw RawWebSocketError("connection closed mid-frame") }
        }
    }

    /// Appends whatever arrives next; false on EOF.
    private func receiveMore() throws -> Bool {
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress!, $0.count, 0) }
            if n > 0 {
                pending += buf[0..<n]
                return true
            }
            if n == 0 { return false }
            if errno == EINTR { continue }
            throw RawWebSocketError("recv() failed: \(errno)")
        }
    }

    private func sendBytes(_ bytes: [UInt8]) throws {
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + offset, bytes.count - offset, flags) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw RawWebSocketError("send() failed: \(errno)") }
            offset += n
        }
    }
}

/// Runs `body` with a connected `RawWebSocket` on a thread of its own, so its blocking
/// reads don't hold a thread the server's connection tasks need.
func withRawWebSocket<R: Sendable>(port: Int, path: String, protocol subprotocol: String? = nil,
                                   _ body: @escaping @Sendable (RawWebSocket) throws -> R) async throws -> R {
    try await withCheckedThrowingContinuation { continuation in
        Thread {
            continuation.resume(with: Result {
                try body(try RawWebSocket(port: port, path: path, protocol: subprotocol))
            })
        }.start()
    }
}
