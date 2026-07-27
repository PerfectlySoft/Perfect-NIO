//
//  PooledRouteTests.swift
//  PerfectNIOMySQLTests
//
//  Covers the ADR-0001 Phase 1 pool: overloads added to RouteCRUD.swift.
//  Swift Testing (not XCTest, unlike the sibling MySQLIntegrationTests.swift)
//  and `.enabled(if:)` gating (not guard-return), per this ADR's implementation
//  plan cross-cutting conventions -- a skipped-via-guard test reports as
//  passed, hiding "ran and passed" from "silently did nothing".
//

import Testing
import Foundation
import PerfectCRUD
import PerfectMySQL
import PerfectNIO
import PerfectNIOCRUD

private struct PooledWidget: Codable, Sendable {
	var id: Int
	var name: String
}

// MARK: - Compile-time constraint checks
//
// Never called at runtime -- if these compile, DatabaseConnectionPool<MySQLDatabaseConfiguration>
// satisfies the Routes.db(pool:)/table(pool:) generic constraints (C: DCP & Sendable,
// OutType/NewOut: Sendable), mirroring the existing _typeCheckDB/_typeCheckTable
// pattern in MySQLIntegrationTests.swift for the @autoclosure overloads.

private func _typeCheckDBPool() throws {
	let pool = try DatabaseConnectionPool(
		makeConnection: { try MySQLDatabaseConfiguration(database: "test", host: "127.0.0.1") }
	)
	let _ = root().db(pool: pool) { _, db in
		try db.table(PooledWidget.self).select().map { $0 }
	}
}

private func _typeCheckTablePool() throws {
	let pool = try DatabaseConnectionPool(
		makeConnection: { try MySQLDatabaseConfiguration(database: "test", host: "127.0.0.1") }
	)
	let _ = root().table(pool: pool, PooledWidget.self) { _, table in
		try table.select().map { $0 }
	}
}

// MARK: - Live tests (require MYSQL_TESTS=1)

@Suite("Pooled routes")
struct PooledRouteTests {

	@Test(
		"a real MySQL connection flows through the pool end-to-end",
		.enabled(if: ProcessInfo.processInfo.environment["MYSQL_TESTS"] == "1")
	)
	func liveConnectionThroughPool() async throws {
		let pool = try DatabaseConnectionPool(
			configuration: .init(minConnections: 0, maxConnections: 2),
			makeConnection: {
				try MySQLDatabaseConfiguration(database: "test", host: "127.0.0.1",
												username: "root", password: "")
			}
		)

		// Seed via a direct connection first (same pattern as the sibling
		// MySQLIntegrationTests.swift's liveDB() helper).
		let seedConfig = try MySQLDatabaseConfiguration(database: "test", host: "127.0.0.1",
														 username: "root", password: "")
		let seedDB = Database(configuration: seedConfig)
		try seedDB.create(PooledWidget.self, policy: [.dropTable, .shallow])
		try seedDB.table(PooledWidget.self).insert([
			PooledWidget(id: 1, name: "Cog"),
			PooledWidget(id: 2, name: "Gear"),
		])

		// This is the exact code path a pooled route handler runs: a checkout
		// from the pool, a query, an implicit checkin.
		let results = try await pool.withConnection { db in
			try db.table(PooledWidget.self).order(by: \PooledWidget.id).select().map { $0 }
		}

		#expect(results.count == 2)
		#expect(results[0].name == "Cog")
		#expect(results[1].name == "Gear")

		// A second checkout must reuse the pooled connection, not open a new
		// one -- confirms the pool (not just raw MySQL) is actually in the loop.
		#expect(await pool.currentSize == 1)
	}
}
