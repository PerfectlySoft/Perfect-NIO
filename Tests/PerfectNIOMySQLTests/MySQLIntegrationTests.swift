//
//  MySQLIntegrationTests.swift
//  PerfectNIOMySQLTests
//
//  Validates that MySQLDatabaseConfiguration satisfies the C: DCP & Sendable
//  generic constraints required by Routes.db() and Routes.table().
//
//  Compile-time tests (prefixed "_typeCheck") verify generic constraint satisfaction
//  without requiring a live MySQL server. They are never called at runtime.
//
//  Live tests (prefixed "testLive") need a MySQL server configured through the
//  MYSQL_TEST_* environment variables (see MySQLTestEnvironment.swift). They are
//  skipped unless MYSQL_TESTS=1 and MYSQL_TEST_PORT are both set.
//

import XCTest
import PerfectCRUD
import PerfectMySQL
import PerfectNIO
import PerfectNIOCRUD

// MARK: - Test model

private struct Widget: Codable, Sendable {
    var id: Int
    var name: String
    var price: Double
}

// MARK: - Compile-time constraint checks

// These functions are never called — the compiler type-checks them at build time.
// If they compile, MySQLDatabaseConfiguration satisfies C: DCP & Sendable.

private func _typeCheckDB() throws {
    let _ = root().db(
        try Database(configuration: MySQLDatabaseConfiguration(
            database: "test", host: "127.0.0.1"
        ))
    ) { _, db in
        try db.table(Widget.self).select().map { $0 }
    }
}

private func _typeCheckTable() throws {
    let _ = root().table(
        try Database(configuration: MySQLDatabaseConfiguration(
            database: "test", host: "127.0.0.1"
        )),
        Widget.self
    ) { _, table in
        try table.select().map { $0 }
    }
}

private func _typeCheckDBChained() throws {
    let _ = root()
        .db(
            try Database(configuration: MySQLDatabaseConfiguration(
                database: "test", host: "127.0.0.1"
            ))
        ) { req, db in
            let count = try db.table(Widget.self).count()
            return ["count": count]
        }
}

// MARK: - XCTestCase

final class MySQLIntegrationTests: XCTestCase {

    // Resolve a live DB configuration, or skip if no test server is configured.
    private func liveDB() throws -> Database<MySQLDatabaseConfiguration> {
        if let reason = MySQLTestEnvironment.skipReason {
            throw XCTSkip(reason)
        }
        try MySQLTestEnvironment.ensureDatabase()
        return Database(configuration: try MySQLTestEnvironment.configuration())
    }

    // MARK: Structural tests (no server required)

    func testMySQLConfigurationConformsToSendable() {
        // Type-system check: verifies at compile time that MySQLDatabaseConfiguration
        // satisfies both DatabaseConfigurationProtocol and Sendable.
        // No connection is attempted — the function only needs to compile.
        func _requiresDCPAndSendable<C: DatabaseConfigurationProtocol & Sendable>(_: C.Type) {}
        _requiresDCPAndSendable(MySQLDatabaseConfiguration.self)
    }

    func testRouteChainTypechecks() {
        // Verify that Routes.db() and Routes.table() accept MySQLDatabaseConfiguration
        // without requiring a server. The autoclosure body is never invoked here.
        let dbRoute = root().db(
            try! Database(configuration: MySQLDatabaseConfiguration(
                database: "test", host: "999.999.999.999"  // unreachable — never invoked
            ))
        ) { _, db in
            try db.table(Widget.self).count()
        }
        XCTAssertNotNil(dbRoute)

        let tableRoute = root().table(
            try! Database(configuration: MySQLDatabaseConfiguration(
                database: "test", host: "999.999.999.999"
            )),
            Widget.self
        ) { _, table in
            try table.select().map { $0 }
        }
        XCTAssertNotNil(tableRoute)
    }

    // MARK: Live tests (require MYSQL_TESTS=1 and MYSQL_TEST_PORT)

    func testLiveCreateAndSelect() async throws {
        let db = try liveDB()
        try db.create(Widget.self, policy: [.dropTable, .shallow])
        try db.table(Widget.self).insert(Widget(id: 1, name: "Sprocket", price: 9.99))
        let results = try db.table(Widget.self).where(\Widget.id == 1).select().map { $0 }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "Sprocket")
    }

    func testLiveRouteDBPattern() async throws {
        let db = try liveDB()
        // Seed data
        try db.create(Widget.self, policy: [.dropTable, .shallow])
        try db.table(Widget.self).insert([
            Widget(id: 1, name: "Alpha", price: 1.0),
            Widget(id: 2, name: "Beta",  price: 2.0),
        ])

        // Simulate the body of a Routes.db() handler — this is the exact code
        // pattern that runs inside the route closure when a request arrives.
        let config = try MySQLTestEnvironment.configuration()
        let results = try await Task {
            let queryDB = Database(configuration: config)
            return try queryDB.table(Widget.self).order(by: \Widget.id).select().map { $0 }
        }.value

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].name, "Alpha")
        XCTAssertEqual(results[1].name, "Beta")
    }
}
