//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// LogCapture — thread-safe ring buffer for the admin console's log-tail display.
//
// Usage:
//   let capture = LogCapture()
//   // Feed lines from wherever the app produces log output:
//   await capture.capture("2026-07-14 10:00:00 [INFO] Server started")
//
// Perfect-Logger / swift-log integration: wrap LogCapture in a custom LogHandler
// that calls capture.capture() for each log entry, then multiplex it alongside
// the existing handler via MultiplexLogHandler.
//
// The capacity defaults to 500 lines. Once full, the oldest line is dropped to
// make room for each new one.
//
// Phase 8 (admin-console UI redesign phase 2, the log viewer component): each
// captured line now carries a real capture-time timestamp and an optional
// isError flag, both additive -- `capture(_:)`'s existing single-argument call
// sites across the ecosystem keep compiling unchanged with isError defaulting
// to false.

import Foundation

/// Thread-safe ring buffer for admin console log display.
public actor LogCapture {

    /// One captured line: the message text, when it was captured, and whether
    /// it should render as an error in the log viewer. `isError` is opt-in --
    /// callers that don't know or care leave it false.
    public struct Entry: Sendable {
        public let timestamp: Date
        public let message: String
        public let isError: Bool

        public init(timestamp: Date = Date(), message: String, isError: Bool = false) {
            self.timestamp = timestamp
            self.message = message
            self.isError = isError
        }
    }

    public nonisolated let capacity: Int
    private var entries: [Entry] = []

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    /// Append a formatted log line. Call from any async context.
    public func capture(_ message: String, isError: Bool = false) {
        if entries.count >= capacity {
            entries.removeFirst()
        }
        entries.append(Entry(message: message, isError: isError))
    }

    /// Returns the last `count` lines, oldest first. Thread-safe.
    public func recentLines(count: Int = 100) -> [String] {
        recentEntries(count: count).map(\.message)
    }

    /// Returns the last `count` captured entries (timestamp + message + isError), oldest first.
    public func recentEntries(count: Int = 100) -> [Entry] {
        let n = min(count, entries.count)
        let start = entries.count - n
        return Array(entries[start...])
    }

    /// Removes all lines from the buffer. Returns the count of lines that were dropped.
    public func clear() -> Int {
        let dropped = entries.count
        entries = []
        return dropped
    }

    /// Total lines currently held in the buffer.
    public var totalCaptured: Int { entries.count }
}
