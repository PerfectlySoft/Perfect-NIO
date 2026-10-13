//
//  SlowReaderTests.swift
//  PerfectNIOSmokeTests
//
//  A client that reads a large response slowly but steadily must get all of it, over plain
//  HTTP and TLS, even when that takes many times the idle timeout.
//

import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
@testable import PerfectNIO

/// A throwaway self-signed certificate (CN=localhost) for local TLS tests only.
let testCertificatePEM = """
-----BEGIN CERTIFICATE-----
MIICpjCCAY4CCQDD0J+8gq9xWDANBgkqhkiG9w0BAQsFADAUMRIwEAYDVQQDDAls
b2NhbGhvc3QwIBcNMjYxMDEzMTkyNTQwWhgPMjEyNjA5MTkxOTI1NDBaMBQxEjAQ
BgNVBAMMCWxvY2FsaG9zdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEB
ALfhyAvE7PK9p+GTGSyR9Li6mPpa4cBoqeGbFH/W0sq9ZB8BC4fhgTFoDWbnnjur
TFjN0qtFdRhBrEErdjtYQbQgMX4bM5h8otS9kPR4zseJ95WEJti8UuBCnPya7b+4
8Ypl39eRBlksraMJmrFKZBXO4IL/HP7wxxWzkrrsiicBUFR6JygLmyjAGSSNUQ7M
rcePVXebii/5gaaDBLRF6xlU9IwFYQ0Q7ByrFqjVkCuO3nLifMSumwcPvM/CMh0x
rL0tLIqKVAzm45mY4vvTJeYgcaczviu5sVgIxYg7o/oRqUlP3J2u84xMqR7I9D/e
W/m7etXuYPlwrPB6CDoD6tcCAwEAATANBgkqhkiG9w0BAQsFAAOCAQEAjAAxgriv
FiNvtnKhwnvewggUjnS3QftYI95fFidoI7CiHFpLDbMi5fTX1e22gpCY5NwuelEa
g97uOOQkjQ3ZqUbt7fanE4A0qtfV9GbxjoESe4VCngLBaC8vXNMzsoGgTpemYiwC
cWZNhxBRSAqrTuysdDDQx2By1M2tP3938lxshIAA7tJGOluWd89QTqBB6f22kP7o
DRBRp5UAWkh+aE4AzNmxrzAwAc40Af5SkMxBWmxjHlJ3UsJXtbqofWOqicsTozkG
Zy20M890Q4n/cx+Xzkt6PmwwIoN2JtV/i4FVuY5pBDiyFhOHiFTdquyfq0VxjnM/
L0H2FNBUF71kCA==
-----END CERTIFICATE-----
"""
let testPrivateKeyPEM = """
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC34cgLxOzyvafh
kxkskfS4upj6WuHAaKnhmxR/1tLKvWQfAQuH4YExaA1m5547q0xYzdKrRXUYQaxB
K3Y7WEG0IDF+GzOYfKLUvZD0eM7HifeVhCbYvFLgQpz8mu2/uPGKZd/XkQZZLK2j
CZqxSmQVzuCC/xz+8McVs5K67IonAVBUeicoC5sowBkkjVEOzK3Hj1V3m4ov+YGm
gwS0ResZVPSMBWENEOwcqxao1ZArjt5y4nzErpsHD7zPwjIdMay9LSyKilQM5uOZ
mOL70yXmIHGnM74rubFYCMWIO6P6EalJT9ydrvOMTKkeyPQ/3lv5u3rV7mD5cKzw
egg6A+rXAgMBAAECggEALaFaqgkBH6+OpHyDR7skdl7frWi2ErAmT/TS3nJptqPO
3567xMlh7Oe8Q6gAbSAx/ut8dsHyr8VEQJvPaCSbkV5XycpoQFPVeGNeQDxmW7/R
74lutmPtUPdWy5yKmQQE9GoZZP35DFH4+LdeatZiBcNjlT5HbMBFNw5rv/UIx2qx
UFghNorrAUbr5ipnd2K4mh6+KhdoFml+CH/wcBDvyHdUhb4o0giSBVPF7tvvx02F
mBuKC563iDcqlTxKuc157JEqhYFpNj4zuQQ6mtStP0AW8PKAyHPVSMg1JAH6YZW9
m22BNUgriyXLVbdrWz2dxIEudfTrBcSdAoH+DsluCQKBgQDfpvaadwk92R9cGsXw
tAbDB/dxkxpiWrGx2OfXHT6k4kUtYL0k+nPivtLaPuDB+jyoTz5FBV8S6RYQFqBj
r+HSnmwC1rUkfXCvH/C8a8lLGPaje25RxSSeMNs7ONpv51ZFzwlMyIUx4lIyERBK
epAi3//ETo4vMq0OszglLyQhXQKBgQDSekTj/2ID9ettiyK6ih6unowIVhGUKtM5
makUHtqSTU1fq0+Pq+VFuFww2ZBVsImHIkEPquXjx4t5LhNnWg6j7B0PFtSfoLkv
PuU/lx4cyjbiIVv2FxRMvZfzzfgPu8Z/tvzmBPadrKoxW+l5w+evNIqZ0Ij/AAVT
WzJ7qEt1wwKBgQCmypKAcaOvvzvW6ZSSxP+B9XABAG6dyPtaIeQMlh/AwYpLpCiK
6kkAYcVHw7rEjwUrlCVhPfdAWBn/F5C3p1RnSYRNvafLtc0SnWRgcJXm7pAJLaUB
UF/VpaPpj6W/7Kt3VkaeP7CtmhYohnc6xBq4F4tb8CWzZzyOiPOnL3fndQKBgQC5
R467UcWbjPDJBnD02r81ojXM5M8mqig0jVKsdpibr1bMP8aSx5PVMvxcuDh5ZiU6
gunY++zQ/YiGjQvhsAIxRJkz/jn/pwE9WNV/i+yjFVMI7qrAUAK7py5LHWYfm4Ga
TaAEcBwUIrnTJ4C4gr7BmbPkwRDHwOHvRdmDx1td9wKBgH321y4GWH3+t/r4mUkA
bVQ/vQkgKM4vD+PusNSJmyCl2JL3VNOmzGJFg18n8uHzs6yzlBhjbm/59S1hvhwc
A0eEVMz1OLylmEhp5ukhBqeEXO+x4pXUURotmaJuiIty2ZgBw6bJCHsA6MZA+KGd
FqdwrwElmtY4y6w70sTNX8vD
-----END PRIVATE KEY-----
"""

func testServerTLS() throws -> TLSConfiguration {
    TLSConfiguration.makeServerConfiguration(
        certificateChain: try NIOSSLCertificate.fromPEMBytes(Array(testCertificatePEM.utf8)).map { .certificate($0) },
        privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(testPrivateKeyPEM.utf8), format: .pem)))
}

/// Reads at most `bytesPerSecond`, 4 KiB at a time with a small receive buffer, until the
/// server closes. Collects everything received.
private final class ThrottledReader: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let bytesPerSecond: Double
    let done: EventLoopPromise<[UInt8]>
    var received: [UInt8] = []
    var started = NIODeadline.now()
    var pump: RepeatedTask?
    init(bytesPerSecond: Double, done: EventLoopPromise<[UInt8]>) {
        self.bytesPerSecond = bytesPerSecond
        self.done = done
    }
    func channelActive(context: ChannelHandlerContext) {
        started = .now()
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        pump = context.eventLoop.scheduleRepeatedTask(initialDelay: .milliseconds(20), delay: .milliseconds(20)) { [weak self] _ in
            guard let self else { return }
            let elapsed = Double((NIODeadline.now() - self.started).nanoseconds) / 1e9
            if Double(self.received.count) < elapsed * self.bytesPerSecond {
                bound.value.read()
            }
        }
        context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received += Self.unwrapInboundIn(data).readableBytesView
    }
    func channelInactive(context: ChannelHandlerContext) {
        pump?.cancel()
        done.succeed(received)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private func throttledGet(port: Int, path: String, tls: Bool, bytesPerSecond: Double) async throws -> [UInt8] {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let result = try await throttledGet(group: group, port: port, path: path, tls: tls, bytesPerSecond: bytesPerSecond)
        try await group.shutdownGracefully()
        return result
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
}

private func throttledGet(group: EventLoopGroup, port: Int, path: String, tls: Bool,
                          bytesPerSecond: Double) async throws -> [UInt8] {
    let done = group.next().makePromise(of: [UInt8].self)
    var clientTLS = TLSConfiguration.makeClientConfiguration()
    clientTLS.certificateVerification = .none
    let sslContext = try NIOSSLContext(configuration: clientTLS)
    let channel = try await ClientBootstrap(group: group)
        .channelOption(ChannelOptions.autoRead, value: false)
        .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 4096))
        .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        .channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 8192)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                if tls {
                    try channel.pipeline.syncOperations.addHandler(try NIOSSLClientHandler(context: sslContext, serverHostname: nil))
                }
                try channel.pipeline.syncOperations.addHandler(ThrottledReader(bytesPerSecond: bytesPerSecond, done: done))
            }
        }
        .connect(host: "127.0.0.1", port: port).get()
    var request = channel.allocator.buffer(capacity: 128)
    request.writeString("GET \(path) HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    try await channel.writeAndFlush(request).get()
    channel.read()
    return try await done.futureResult.get()
}

@Suite("Slow readers")
struct SlowReaderTests {
    /// Each body chunk used to be one write that completed only once the client had read all
    /// of it, and the response counted as over when its end was queued; a reader slower than
    /// about chunk size / timeout was cut off mid-body (the review saw 923 KB of 8 MB at
    /// 100 KB/s with a 2 s timeout, and TLS the same).
    ///
    /// TCP itself delivers in bursts (a receiver reopens its window only after reading a good
    /// part of its buffer), so the timeout has to be longer than those gaps: here 4 s, against
    /// responses that take 8-10 s at 40-150 KB/s.
    @Test("A slow, steady reader gets the whole body",
          arguments: [(false, 150_000.0, 1_200_000), (true, 150_000.0, 1_200_000), (false, 40_000.0, 400_000)])
    func slowSteadyReader(tls: Bool, bytesPerSecond: Double, size: Int) async throws {
        let routes = root().path("big").map { BytesOutput(body: Array(repeating: 0x61, count: size)) as HTTPOutput }
        let server = Server(routes: routes, port: 0, tls: tls ? try testServerTLS() : nil, idleTimeout: .seconds(4))
        try await server.withServer { port in
            let bytes = try await throttledGet(port: port, path: "/big", tls: tls, bytesPerSecond: bytesPerSecond)
            let text = String(decoding: bytes.prefix(512), as: UTF8.self)
            let headLength = text.range(of: "\r\n\r\n").map { text[..<$0.upperBound].utf8.count } ?? 0
            #expect(text.hasPrefix("HTTP/1.1 200"), "\(text.prefix(80))")
            #expect(bytes.count - headLength == size, "tls: \(tls), \(bytesPerSecond) B/s")
        }
    }
}
