//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// DatasourceProbe — sanitized connection descriptor and on-demand test result.
//
// Host applications supply DatasourceInfo objects via AdminConsoleDelegate
// to make their datasource connections visible in the admin console without
// exposing credentials.  The host also implements testDatasource(name:) to
// run a real connectivity check when the operator clicks "Test" in the UI.
//
// Credentials must never appear in DatasourceInfo.  Only pass alias, schema
// name, and driver type — information that is safe to display to the operator.

import Foundation

/// Describes one named configuration that a datasource can be switched to at runtime.
///
/// Config switching is intentionally framework-agnostic: the `id` is an opaque string
/// passed back to `AdminConsoleDelegate.switchDatasource(name:to:)`. The host decides
/// what it means — a file path, an environment name, a key in a config dictionary, etc.
///
/// **Examples:**
/// - Lasso: id = path to an alternate `.conf` file
/// - MySQL pool: id = `"staging"` triggering a host reconfiguration in the pool
/// - Custom API: id = an env profile name (`"dev"`, `"staging"`, `"prod"`)
///
/// Credentials must never appear in `label` or `description`. Those fields are
/// displayed to whoever has authenticated to the admin console.
public struct DatasourceConfigInfo: Sendable {
    /// Opaque identifier passed to `switchDatasource(name:to:)`. Use stable lowercase-kebab strings.
    public let id: String
    /// Short human-readable label shown in the switcher dropdown (e.g. `"Staging"`, `"Production"`).
    public let label: String
    /// One-line description displayed below the label — schema name, server alias, or similar.
    /// Never include passwords, tokens, or connection strings containing credentials.
    public let description: String
    /// Whether this config is currently active. The UI highlights the active entry.
    public let isActive: Bool

    public init(id: String, label: String, description: String, isActive: Bool = false) {
        self.id = id
        self.label = label
        self.description = description
        self.isActive = isActive
    }
}

/// Sanitized description of one datasource connection.
///
/// **No password or host credentials.** Return only what is safe to display
/// to an operator who has already authenticated to the admin console.
public struct DatasourceInfo: Sendable {
    /// Unique key used in `AdminConsoleDelegate.testDatasource(name:)`.
    /// Use a stable, lowercase-kebab identifier (e.g. `"mysql-main"`, `"redis-cache"`).
    public let name: String
    /// Human-readable label shown in the UI — e.g. a Lasso alias or environment variable name.
    public let alias: String
    /// Database or schema name. For FileMaker, the file name. For Redis, the db index as a string.
    public let schema: String
    /// Driver type label — e.g. `"MySQL"`, `"PostgreSQL"`, `"Redis"`, `"FileMaker"`, `"SQLite"`.
    public let driver: String

    public init(name: String, alias: String, schema: String, driver: String) {
        self.name = name
        self.alias = alias
        self.schema = schema
        self.driver = driver
    }
}

/// The outcome of an on-demand datasource connectivity test.
public struct DatasourceTestResult: Sendable {
    public let success: Bool
    /// Human-readable status message shown as a toast and in the log tail.
    public let message: String
    /// Round-trip latency of the test query, if the test completed. `nil` on failure before a response.
    public let latencyMs: Double?

    public init(success: Bool, message: String, latencyMs: Double? = nil) {
        self.success = success
        self.message = message
        self.latencyMs = latencyMs
    }

    /// Convenience factory for a successful test.
    public static func ok(latencyMs: Double? = nil, message: String = "Connection OK") -> DatasourceTestResult {
        DatasourceTestResult(success: true, message: message, latencyMs: latencyMs)
    }

    /// Convenience factory for a failed test.
    public static func failed(_ message: String) -> DatasourceTestResult {
        DatasourceTestResult(success: false, message: message, latencyMs: nil)
    }
}
