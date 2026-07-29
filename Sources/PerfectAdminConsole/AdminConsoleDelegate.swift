//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// AdminConsoleDelegate — protocol for the host application to supply live
// server state to the admin console's status, route, and action displays.
//
// All methods have default no-op implementations: conformance is additive.
// The host implements only what it wants to expose.
//
// Phase 1: status sections, route inspector
// Phase 2: custom actions, TLS certificate reload
// Phase 6: model schema browser (ADR-0001 Phase 5 -- see ModelInfo.swift's
// header comment for why the numbering doesn't line up: this file's own
// Phase N is local to PerfectAdminConsole's build history, unrelated to
// ADR-0001's PerfectCRUD roadmap phase numbers)
// Phase 7: the currently-running-job hook, added for the admin-console UI
// redesign's shared state-strip chip (see AdminWebUI.swift's header comment)

import Foundation

/// A single route visible in the admin console's route inspector.
public struct RouteInfo: Sendable {
    public let uri: String
    public init(uri: String) { self.uri = uri }
}

/// A key-value section contributed by the host to the admin status page.
/// Use for application-specific info (e.g. Lasso startup results, datasource alias map).
public struct AdminStatusSection: Sendable {
    public let title: String
    public let items: [(key: String, value: String)]

    public init(title: String, items: [(key: String, value: String)]) {
        self.title = title
        self.items = items
    }
}

/// A long-running background job, surfaced in the admin console's shared state-strip chip —
/// visible on every tab, not just the one that started it. `completed`/`total` drive a progress
/// bar; the console has no notion of what a "job" is beyond this triple, so any host-specific
/// concept (a crawl report, a migration, a bulk export) maps onto it the same way.
public struct AdminRunningJob: Sendable {
    public let name: String
    public let completed: Int
    public let total: Int

    public init(name: String, completed: Int, total: Int) {
        self.name = name
        self.completed = completed
        self.total = total
    }
}

/// Protocol for the host application to supply live server state to the admin console.
/// Conformers must be `Sendable`; actors satisfy this automatically.
public protocol AdminConsoleDelegate: AnyObject, Sendable {
    // MARK: Phase 1 — status display

    /// The port the main application server is listening on. Return 0 to omit.
    var serverPort: Int { get }
    /// When the server process started — used for uptime display.
    var serverStartTime: Date { get }
    /// Routes registered on the main server, for the route inspector.
    var registeredRoutes: [RouteInfo] { get }
    /// Optional extra sections shown below the standard status cards.
    func additionalStatusSections() async -> [AdminStatusSection]

    // MARK: Phase 2 — actions

    /// Custom actions offered by this host. Combined with built-in actions in the console.
    /// Return an empty array (default) to suppress the actions panel.
    func availableActions() async -> [AdminAction]

    // MARK: Phase 4 — TLS operations

    /// Called when the operator requests a per-domain certificate reload.
    ///
    /// Implement to re-read PEM files for `hostname` and push the new context to
    /// `TLSContextManager`. If you use `CertificateWatcher`, call `watcher.reload()`.
    /// Default falls back to `reloadTLSCertificates()` (reload-all) so existing Phase 2
    /// conformers get sensible behaviour without any code change.
    func reloadTLSCertificate(for hostname: String) async throws

    // MARK: Phase 3 — datasource management

    /// All datasource connections to surface in the admin console.
    /// Return only sanitized info: alias + schema name, **never** credentials.
    func registeredDatasources() async -> [DatasourceInfo]

    /// Test a specific named datasource connection on demand.
    ///
    /// Only called for `name` values returned by `registeredDatasources()`.
    /// Return `.failed("reason")` rather than throwing — that produces a clean
    /// toast notification rather than a 500 error in the UI.
    func testDatasource(name: String) async throws -> DatasourceTestResult

    // MARK: Phase 5 — live datasource config switching

    /// The named configurations available for a specific datasource.
    ///
    /// Return an empty array (default) to suppress the config switcher for that datasource.
    /// Mark exactly one entry `isActive: true` to show the current selection in the UI.
    ///
    /// - Note: Config identity is opaque — `id` is whatever string your host uses to
    ///   identify a configuration (file path, env profile name, pool key, etc.). The admin
    ///   console passes it back verbatim to `switchDatasource(name:to:)`.
    func availableConfigs(for datasource: String) async -> [DatasourceConfigInfo]

    /// Switch a named datasource to a different configuration at runtime.
    ///
    /// Only called with `configID` values returned by `availableConfigs(for:)`.
    /// Return a `DatasourceTestResult` — the framework shows it as a toast and logs it.
    /// Return `.failed("reason")` rather than throwing so the UI gets a clean message.
    ///
    /// Typical implementations:
    /// - Lasso: reload a different `.conf` file and reinitialise the datasource alias
    /// - MySQL pool: drain the pool and reconnect with new credentials from a different profile
    /// - Custom API: swap environment variables and reconnect
    func switchDatasource(name: String, to configID: String) async throws -> DatasourceTestResult

    /// Execute a custom action by name. Only called for names returned by `availableActions()`.
    /// Return `.failed` rather than throwing to send a friendly error message to the UI.
    func executeAction(_ name: String) async throws -> AdminActionResult

    /// Called when the operator triggers the built-in "reload-tls" action.
    /// Implement to re-read certificate PEM files and push them to your `TLSContextManager`.
    /// Default implementation is a no-op (the built-in action will report success silently).
    func reloadTLSCertificates() async throws

    // MARK: Phase 6 — model schema browser (ADR-0001 Phase 5)

    /// Models/tables to surface in the admin console's schema browser.
    ///
    /// PerfectAdminConsole has no PerfectCRUD dependency -- convert your own
    /// reflected schema (e.g. `SomeModel.CRUDTableStructure()`) into
    /// `ModelInfo` here. Return an empty array (default) to suppress the
    /// panel. Schema only, never row data.
    func registeredModels() async -> [ModelInfo]

    // MARK: Phase 7 — currently-running job

    /// The job currently in flight, if any — shown in the state strip's running-job chip on
    /// every tab. Return `nil` (default) when nothing is running; the chip is simply absent.
    func currentJob() async -> AdminRunningJob?
}

public extension AdminConsoleDelegate {
    var serverPort: Int { 0 }
    var serverStartTime: Date { .distantFuture }
    var registeredRoutes: [RouteInfo] { [] }
    func additionalStatusSections() async -> [AdminStatusSection] { [] }
    func availableActions() async -> [AdminAction] { [] }
    func executeAction(_ name: String) async throws -> AdminActionResult {
        .failed("Unknown action: \(name)")
    }
    func reloadTLSCertificates() async throws {}
    func reloadTLSCertificate(for hostname: String) async throws { try await reloadTLSCertificates() }
    func registeredDatasources() async -> [DatasourceInfo] { [] }
    func testDatasource(name: String) async throws -> DatasourceTestResult {
        .failed("No datasource named '\(name)' is registered")
    }
    func availableConfigs(for datasource: String) async -> [DatasourceConfigInfo] { [] }
    func switchDatasource(name: String, to configID: String) async throws -> DatasourceTestResult {
        .failed("Config switching not supported for '\(name)'")
    }
    func registeredModels() async -> [ModelInfo] { [] }
    func currentJob() async -> AdminRunningJob? { nil }
}
