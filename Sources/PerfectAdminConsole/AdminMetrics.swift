//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// AdminMetrics — lightweight in-process request counters for the admin console.
//
// No Prometheus, no StatsD — just enough to answer "is this route being hit"
// and "what is the current error rate" without adding external dependencies.
//
// Usage (in the host application's route handlers):
//   let metrics = AdminMetrics()
//   let admin = try AdminConsole(..., metrics: metrics, ...)
//
//   // In each request handler:
//   await metrics.recordRequest(route: "GET:///api/posts")
//
//   // On error paths:
//   await metrics.recordError()
//
//   // Around connection lifetime (optional — for active-connection tracking):
//   await metrics.beginConnection()
//   defer { Task { await metrics.endConnection() } }

import Foundation

/// In-process request counter actor. Feed from your route handlers to populate
/// the admin console's Metrics card. Thread-safe: all mutations are actor-isolated.
public actor AdminMetrics {
    private var totalRequests: Int = 0
    private var totalErrors: Int = 0
    private var activeConnections: Int = 0
    private var routeCounts: [String: Int] = [:]

    /// Recent request/error counts, bucketed by 5-minute window, for the admin console's
    /// Traffic sparkline. In-memory only, resets on restart — consistent with every other
    /// counter on this actor. 12 buckets covers a 1-hour trailing window.
    private struct RateBucket {
        var windowStart: Date
        var requests = 0
        var errors = 0
    }
    private var rateBuckets: [RateBucket] = []
    private let rateBucketSeconds: TimeInterval = 300
    private let rateBucketCount = 12

    public init() {}

    /// Record one completed request for the given route key.
    /// Use the PerfectNIO route key format: `"METHOD:///path"` (e.g. `"GET:///api/posts"`).
    public func recordRequest(route: String) {
        totalRequests += 1
        routeCounts[route, default: 0] += 1
        rateBuckets[currentRateBucketIndex()].requests += 1
    }

    /// Record one error response (4xx/5xx). Call after `recordRequest` on error paths.
    public func recordError() {
        totalErrors += 1
        rateBuckets[currentRateBucketIndex()].errors += 1
    }

    /// Returns the index of the current time bucket, appending a new one (and evicting the
    /// oldest past `rateBucketCount`) whenever the current bucket has aged out.
    private func currentRateBucketIndex() -> Int {
        let now = Date()
        if let last = rateBuckets.last, now.timeIntervalSince(last.windowStart) < rateBucketSeconds {
            return rateBuckets.count - 1
        }
        rateBuckets.append(RateBucket(windowStart: now))
        if rateBuckets.count > rateBucketCount {
            rateBuckets.removeFirst(rateBuckets.count - rateBucketCount)
        }
        return rateBuckets.count - 1
    }

    /// Point-in-time snapshot of the trailing rate-bucket history, oldest first.
    public func requestRateHistory() -> [RateBucketSnapshot] {
        rateBuckets.map {
            RateBucketSnapshot(windowStartUnix: $0.windowStart.timeIntervalSince1970, requests: $0.requests, errors: $0.errors)
        }
    }

    /// Increment the active-connection counter. Call when a new connection opens.
    public func beginConnection() {
        activeConnections += 1
    }

    /// Decrement the active-connection counter. Call when a connection closes.
    /// Clamps at zero — safe to call if `beginConnection` was never called.
    public func endConnection() {
        if activeConnections > 0 { activeConnections -= 1 }
    }

    /// Return a point-in-time snapshot of all counters. Safe to call from any context.
    public func snapshot() -> MetricsSnapshot {
        MetricsSnapshot(
            totalRequests: totalRequests,
            totalErrors: totalErrors,
            activeConnections: activeConnections,
            routeCounts: routeCounts,
            rateHistory: requestRateHistory()
        )
    }
}

/// One 5-minute bucket of request/error counts, for the admin console's Traffic sparkline.
public struct RateBucketSnapshot: Sendable, Encodable {
    public let windowStartUnix: Double
    public let requests: Int
    public let errors: Int

    public init(windowStartUnix: Double, requests: Int, errors: Int) {
        self.windowStartUnix = windowStartUnix
        self.requests = requests
        self.errors = errors
    }
}

/// A point-in-time snapshot of AdminMetrics counters.
///
/// `Encodable` so it can be returned directly from the `/api/metrics` handler.
public struct MetricsSnapshot: Sendable, Encodable {
    public let totalRequests: Int
    public let totalErrors: Int
    public let activeConnections: Int
    /// Per-route hit counts. Key is the PerfectNIO route key (`"METHOD:///path"`).
    public let routeCounts: [String: Int]
    /// Trailing rate-bucket history, oldest first, for the Traffic sparkline.
    public let rateHistory: [RateBucketSnapshot]

    /// Error rate as a fraction of total requests. Zero when no requests have been recorded.
    public var errorRate: Double {
        totalRequests > 0 ? Double(totalErrors) / Double(totalRequests) : 0.0
    }

    public init(totalRequests: Int, totalErrors: Int, activeConnections: Int, routeCounts: [String: Int], rateHistory: [RateBucketSnapshot] = []) {
        self.totalRequests = totalRequests
        self.totalErrors = totalErrors
        self.activeConnections = activeConnections
        self.routeCounts = routeCounts
        self.rateHistory = rateHistory
    }

    private enum CodingKeys: String, CodingKey {
        case totalRequests, totalErrors, activeConnections, routeCounts, errorRate, rateHistory
    }

    // `errorRate` is computed, not stored, so synthesized Encodable would silently
    // drop it from the JSON response. Encode it explicitly instead.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalRequests, forKey: .totalRequests)
        try container.encode(totalErrors, forKey: .totalErrors)
        try container.encode(activeConnections, forKey: .activeConnections)
        try container.encode(routeCounts, forKey: .routeCounts)
        try container.encode(errorRate, forKey: .errorRate)
        try container.encode(rateHistory, forKey: .rateHistory)
    }
}
