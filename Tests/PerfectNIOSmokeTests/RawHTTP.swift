//
//  RawHTTP.swift
//  PerfectNIOSmokeTests
//
//  A blocking TCP client for tests that need byte-level control over a request:
//  a body shorter than its Content-Length, hand-written chunked framing, or
//  Expect: 100-continue. Plain sockets rather than NIO so it can run inside
//  exit tests without its own event loop.
//

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct RawHTTPResponse {
    /// Everything received, decoded as Latin-1 so arbitrary bytes survive.
    let text: String
    /// True if the server closed the connection (EOF or reset) before the read timed out.
    let closed: Bool
    /// Seconds from connect until reading stopped.
    let elapsed: Double
    /// Request bytes the server accepted before sending stopped.
    var sent = 0

    /// The status code from the first status line, if one arrived.
    var status: Int? {
        guard text.hasPrefix("HTTP/"), let line = text.split(separator: "\r\n").first else { return nil }
        let fields = line.split(separator: " ")
        return fields.count > 1 ? Int(fields[1]) : nil
    }

    /// The body of the first response, using its Content-Length (counted in bytes, which are
    /// the unicode scalars of the Latin-1 `text`).
    var body: String {
        guard let split = text.range(of: "\r\n\r\n") else { return "" }
        let head = text[..<split.lowerBound].lowercased()
        let rest = text[split.upperBound...].unicodeScalars
        guard let line = head.split(separator: "\r\n").first(where: { $0.hasPrefix("content-length:") }),
              let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) else {
            return String(rest)
        }
        return String(String.UnicodeScalarView(rest.prefix(length)))
    }
}

/// Connects to 127.0.0.1:`port`, sends each of `parts` in order (stopping quietly if the server
/// closes first), then reads until the server closes or `timeout` seconds pass without data.
func rawHTTP(port: Int, _ parts: [[UInt8]], timeout: Double = 5) -> RawHTTPResponse {
    let start = Date()
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let sendFlags: Int32 = 0
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    let sendFlags = Int32(MSG_NOSIGNAL)
    #endif
    precondition(fd >= 0, "socket() failed")
    defer { close(fd) }

    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
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
    precondition(connected == 0, "connect() failed: \(errno)")

    var sent = 0
    sending: for part in parts {
        var offset = 0
        while offset < part.count {
            let n = part.withUnsafeBytes { send(fd, $0.baseAddress! + offset, part.count - offset, sendFlags) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break sending }
            offset += n
            sent += n
        }
    }

    var received: [UInt8] = []
    var closed = false
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress!, $0.count, 0) }
        if n > 0 {
            received += buf[0..<n]
        } else if n < 0 && errno == EINTR {
            continue
        } else {
            closed = n == 0 || errno == ECONNRESET
            break
        }
    }
    let text = String(received.map { Character(Unicode.Scalar($0)) })
    return RawHTTPResponse(text: text, closed: closed, elapsed: Date().timeIntervalSince(start), sent: sent)
}

/// A request head as bytes. `headers` are written in order after Host.
func rawHead(_ method: String, _ path: String, _ headers: [(String, String)] = []) -> [UInt8] {
    var s = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    for (name, value) in headers { s += "\(name): \(value)\r\n" }
    s += "\r\n"
    return Array(s.utf8)
}

/// One chunk in chunked transfer encoding.
func rawChunk(_ bytes: [UInt8]) -> [UInt8] {
    Array(String(bytes.count, radix: 16).utf8) + [13, 10] + bytes + [13, 10]
}

let rawLastChunk: [UInt8] = Array("0\r\n\r\n".utf8)

/// `rawHTTP` on a thread of its own, so its blocking reads don't hold a thread the server's
/// connection tasks need. (Not a Dispatch queue: on Linux the global concurrent queues and
/// Swift's global executor share one thread pool.)
func rawHTTP(port: Int, _ parts: [[UInt8]], timeout: Double = 5) async -> RawHTTPResponse {
    await withCheckedContinuation { continuation in
        Thread {
            continuation.resume(returning: rawHTTP(port: port, parts, timeout: timeout) as RawHTTPResponse)
        }.start()
    }
}
