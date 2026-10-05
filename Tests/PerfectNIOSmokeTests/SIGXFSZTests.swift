//
//  SIGXFSZTests.swift
//  PerfectNIOSmokeTests
//
//  Under an RLIMIT_FSIZE, an upload that writes past the limit raises SIGXFSZ.
//  Its default action kills the process, so the server has to ignore it for the
//  write to fail with EFBIG (which MimeReader turns into 413). Signal
//  dispositions and resource limits are process-wide, so these are exit tests.
//
//  Each test resets SIGXFSZ to SIG_DFL first: ignored signals survive exec, so
//  if the test runner itself ever ignored it, the child would start out ignoring
//  it too and the tests would pass without the server doing anything.
//
//  The signal mask matters too. Swift concurrency runs on Dispatch worker threads,
//  which block SIGXFSZ, and that's where uploads are written. On Darwin the signal
//  from write(2) goes to the process, so it's delivered to (and kills via) any
//  thread that doesn't block it, such as a server's parked main thread. On Linux
//  it goes to the writing thread and stays pending there. The tests make the
//  unblocked thread explicit so the outcome doesn't depend on which threads the
//  test harness happens to have.
//

import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import PerfectNIO

#if !SWT_NO_EXIT_TESTS

private func setFileSizeLimit(_ bytes: rlim_t?) {
    var lim = rlimit()
    #if canImport(Glibc)
    let resource = __rlimit_resource_t(RLIMIT_FSIZE.rawValue)
    #else
    let resource = RLIMIT_FSIZE
    #endif
    getrlimit(resource, &lim)
    lim.rlim_cur = bytes ?? lim.rlim_max
    guard setrlimit(resource, &lim) == 0 else { exit(90) }
}

private func unblockSIGXFSZOnThisThread() {
    var set = sigset_t()
    sigemptyset(&set)
    sigaddset(&set, SIGXFSZ)
    pthread_sigmask(SIG_UNBLOCK, &set, nil)
}

/// Starts a thread that doesn't block SIGXFSZ and just waits, like the main thread of a
/// server parked in `run()`. Returns once the thread is running.
private func startThreadWithSIGXFSZUnblocked() {
    let ready = DispatchSemaphore(value: 0)
    let thread = Thread {
        unblockSIGXFSZOnThisThread()
        ready.signal()
        while true { sleep(60) }
    }
    thread.start()
    ready.wait()
}

/// A process-directed signal may be delivered to another thread a moment after write(2)
/// returns, so give it time to land before reporting that the process survived.
private func awaitPendingSignals() {
    usleep(500_000)
}

/// The current SIGXFSZ handler, as raw bits: 0 is SIG_DFL, 1 is SIG_IGN.
private func sigxfszHandlerBits() -> Int {
    var sa = sigaction()
    sigaction(SIGXFSZ, nil, &sa)
    #if os(Linux)
    return unsafeBitCast(sa.__sigaction_handler.sa_handler, to: Int.self)
    #else
    return unsafeBitCast(sa.__sigaction_u.__sa_handler, to: Int.self)
    #endif
}

private func uploadRequest(fileBytes: Int) -> [UInt8] {
    let boundary = "XFSZBoundary"
    var body = Array("--\(boundary)\r\nContent-Disposition: form-data; name=\"f\"; filename=\"big.bin\"\r\n".utf8)
    body += Array("Content-Type: application/octet-stream\r\n\r\n".utf8)
    body += [UInt8](repeating: 0x7A, count: fileBytes)
    body += Array("\r\n--\(boundary)--\r\n".utf8)
    return rawHead("POST", "/upload", [("Content-Type", "multipart/form-data; boundary=\(boundary)"),
                                       ("Content-Length", "\(body.count)"), ("Connection", "close")]) + body
}

private let uploadRoutes = root().POST.path("upload").readBody { (_, content) -> String in
    guard case .multiPartForm(let mime) = content else { return "not multipart" }
    return "\(mime.bodySpecs.map(\.fileSize))"
}.text()

@Suite("SIGXFSZ")
struct SIGXFSZTests {

    /// Control: with SIGXFSZ at its default, writing past the limit kills the process. This is
    /// what happened to the server on main.
    @Test func defaultActionKillsTheProcess() async {
        await #expect(processExitsWith: .signal(SIGXFSZ)) {
            signal(SIGXFSZ, SIG_DFL)
            let file = TempUploadFile(withPrefix: NSTemporaryDirectory() + "perfect-nio-xfsz-")
            setFileSizeLimit(16)
            unblockSIGXFSZOnThisThread()
            _ = try? file.write(bytes: [UInt8](repeating: 1, count: 64), dataPosition: 0, length: 64)
            setFileSizeLimit(nil)
            file.delete()
            awaitPendingSignals()
            exit(0)
        }
    }

    /// An upload larger than RLIMIT_FSIZE gets 413 and the server keeps running. On main, on
    /// macOS, the server process died of SIGXFSZ during the upload.
    /// Exit codes: 2 = wrong status, 3 = server not answering afterwards.
    @Test func oversizedUploadIs413InsteadOfKillingTheServer() async {
        await #expect(processExitsWith: .exitCode(0)) {
            signal(SIGXFSZ, SIG_DFL)
            startThreadWithSIGXFSZUnblocked()
            var status: Int32 = 0
            try await Server(routes: uploadRoutes, port: 0).withServer { port in
                setFileSizeLimit(1024)
                let refused = await rawHTTP(port: port, [uploadRequest(fileBytes: 64 * 1024)])
                let accepted = await rawHTTP(port: port, [uploadRequest(fileBytes: 100)])
                setFileSizeLimit(nil)
                if refused.status != 413 || refused.body != "Uploaded file is too large." {
                    status = 2
                } else if accepted.status != 200 || accepted.body != "[100]" {
                    status = 3
                }
            }
            awaitPendingSignals()
            exit(status)
        }
    }

    /// The server only replaces the default disposition; a handler the app installed first is
    /// left alone. Exit codes: 2 = handler replaced.
    @Test func appInstalledHandlerIsKept() async {
        await #expect(processExitsWith: .exitCode(0)) {
            signal(SIGXFSZ, { _ in })
            let before = sigxfszHandlerBits()
            try await Server(routes: uploadRoutes, port: 0).withServer { _ in }
            exit(sigxfszHandlerBits() == before ? 0 : 2)
        }
    }

    /// Starting a server sets SIGXFSZ to ignored when it was at the default.
    /// Exit codes: 2 = not at default to begin with, 3 = not ignored after start.
    @Test func serverStartIgnoresTheDefault() async {
        await #expect(processExitsWith: .exitCode(0)) {
            signal(SIGXFSZ, SIG_DFL)
            guard sigxfszHandlerBits() == 0 else { exit(2) }
            try await Server(routes: uploadRoutes, port: 0).withServer { _ in }
            exit(sigxfszHandlerBits() == 1 ? 0 : 3)
        }
    }
}

#endif
