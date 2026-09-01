//
//  ServerReusePortTests.swift
//  PerfectNIOSmokeTests
//
//  Covers `Server.alwaysReusePort` — the primitive a graceful, hand-off
//  restart (a new process binding the same port before the old one exits)
//  depends on. Without it, a second `Server` bound to the same port throws
//  "address already in use"; with it, both can be bound concurrently.
//

import XCTest
import Foundation
import NIO
import NIOCore
import NIOPosix
import NIOHTTP1
@testable import PerfectNIO

final class ServerReusePortTests: XCTestCase {

    private let port = 42199

    private func routes(_ text: String) -> Routes<HTTPRequest, HTTPOutput> {
        root { text }.text()
    }

    /// The behavior the whole restart design depends on: a second, independent `Server`
    /// bound to the identical port succeeds while the first is still running, when both
    /// opt into `alwaysReusePort`.
    func testTwoServersWithAlwaysReusePortCanBindTheSamePortConcurrently() async throws {
        try await Server(routes: routes("first"), port: port, alwaysReusePort: true).withServer { _ in
            // Second server, same port, while the first is still bound and serving.
            // Must not throw "address already in use".
            try await Server(routes: routes("second"), port: port, alwaysReusePort: true).withServer { _ in
                // Both bound successfully — that's the property under test. Which one
                // actually answers a given request is a kernel load-balancing decision,
                // not something this test needs to pin down.
            }
        }
    }

    /// Without `alwaysReusePort` (the default), today's exclusive-bind behavior is
    /// unchanged — a second server on the same port still fails to bind.
    func testWithoutAlwaysReusePortSecondBindStillFails() async throws {
        try await Server(routes: routes("first"), port: port).withServer { _ in
            do {
                try await Server(routes: routes("second"), port: port).withServer { _ in
                    XCTFail("expected the second bind to fail without alwaysReusePort")
                }
            } catch {
                // Expected: address already in use.
            }
        }
    }

    /// `reusePortCount > 1` (multiple sockets within one process, existing behavior)
    /// is unaffected by the new parameter's default.
    func testReusePortCountGreaterThanOneStillBindsMultipleSocketsInOneProcess() async throws {
        try await Server(routes: routes("multi"), port: port, reusePortCount: 2).withServer { _ in
            // Binding succeeds with multiple internal sockets, exactly as before —
            // no regression from adding `alwaysReusePort` alongside `reusePortCount`.
        }
    }
}
