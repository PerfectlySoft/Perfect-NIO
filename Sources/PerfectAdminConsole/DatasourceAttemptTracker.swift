//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// DatasourceAttemptTracker — in-memory, per-alias ring buffer of connectivity
// attempts (admin-console UI redesign phase 4, the Data tab).
//
// Unlike LogCapture/AdminMetrics, nothing outside this package's own two
// datasource routes (POST /api/datasources/test, POST /api/datasources/switch)
// ever needs to write here: every real host's testDatasource(name:)/
// switchDatasource(name:to:) call already flows through those routes, so the
// tracker gets real data immediately with no delegate protocol change and no
// host-side wiring. It is owned entirely internally by AdminConsole, the same
// way AdminTokenStore is -- not accepted as an init parameter.

import Foundation

/// One recorded connectivity attempt for a datasource alias.
struct DatasourceAttempt: Sendable {
    let timestamp: Date
    /// The profile label active at the time of this attempt -- the currently-active
    /// config's label for a test, or the newly-selected config's label for a switch.
    /// Not an opaque config `id`: this is what's shown to the operator and matched
    /// against `DatasourceConfigInfo.label` for the failure-correlation sentence.
    let profile: String
    let latencyMs: Double?
    let success: Bool
    let message: String

    init(timestamp: Date = Date(), profile: String, latencyMs: Double? = nil, success: Bool, message: String) {
        self.timestamp = timestamp
        self.profile = profile
        self.latencyMs = latencyMs
        self.success = success
        self.message = message
    }
}

enum DatasourceAttemptStatus: String, Sendable {
    case ok
    case failing
    case notTested = "not-tested"
}

/// Everything the `/api/datasources` route needs for one alias, computed from its history.
struct DatasourceAttemptSnapshot: Sendable {
    let status: DatasourceAttemptStatus
    let consecutiveFailures: Int
    let lastAttempt: DatasourceAttempt?
    /// Oldest-first, capped at the tracker's capacity -- matches LogCapture's convention.
    let history: [DatasourceAttempt]
}

/// In-process, in-memory ring buffer of connectivity attempts, keyed by alias name.
actor DatasourceAttemptTracker {
    private var byAlias: [String: [DatasourceAttempt]] = [:]
    private let capacity: Int

    init(capacity: Int = 20) {
        self.capacity = max(1, capacity)
    }

    func record(alias: String, profile: String, result: DatasourceTestResult) {
        var arr = byAlias[alias] ?? []
        arr.append(DatasourceAttempt(profile: profile, latencyMs: result.latencyMs,
                                      success: result.success, message: result.message))
        if arr.count > capacity {
            arr.removeFirst(arr.count - capacity)
        }
        byAlias[alias] = arr
    }

    func snapshot(for alias: String) -> DatasourceAttemptSnapshot {
        let history = byAlias[alias] ?? []
        return DatasourceAttemptSnapshot(
            status: datasourceAttemptStatus(from: history),
            consecutiveFailures: datasourceConsecutiveFailures(in: history),
            lastAttempt: history.last,
            history: history
        )
    }
}

// MARK: - Pure helpers (no actor hop -- directly unit-testable, same convention as
// adminHasTLSConfigured/adminInertActionRejection in AdminConsole.swift)

func datasourceAttemptStatus(from history: [DatasourceAttempt]) -> DatasourceAttemptStatus {
    guard let last = history.last else { return .notTested }
    return last.success ? .ok : .failing
}

func datasourceConsecutiveFailures(in history: [DatasourceAttempt]) -> Int {
    var count = 0
    for attempt in history.reversed() {
        if attempt.success { break }
        count += 1
    }
    return count
}

/// Builds the failure banner's correlation sentence. Scans `history` (oldest-first)
/// backwards for the most recent "profile change" -- an attempt whose `profile` differs
/// from the one immediately before it -- and checks whether every attempt from that
/// point onward failed. If so, names that profile (with its `description` from
/// `configs` when found) and states `consecutiveFailures`. Otherwise falls back to a
/// bare count. Returns `nil` only when there's nothing to say (no failures).
func datasourceFailureSentence(
    history: [DatasourceAttempt],
    consecutiveFailures: Int,
    configs: [DatasourceConfigInfo]
) -> String? {
    guard consecutiveFailures > 0, !history.isEmpty else { return nil }
    var changeIndex: Int?
    for i in stride(from: history.count - 1, through: 1, by: -1) {
        if history[i].profile != history[i - 1].profile {
            changeIndex = i
            break
        }
    }
    if let idx = changeIndex, history[idx...].allSatisfy({ !$0.success }) {
        let profile = history[idx].profile
        let suffix = configs.first(where: { $0.label == profile }).map { " (\($0.description))" } ?? ""
        let times = consecutiveFailures == 1 ? "occurrence" : "occurrences"
        return "Began right after this alias was switched to \(profile)\(suffix). \(consecutiveFailures) \(times) since."
    }
    let times = consecutiveFailures == 1 ? "failure" : "failures"
    return "\(consecutiveFailures) consecutive \(times)."
}
