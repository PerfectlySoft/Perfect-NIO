//
//  LiveServerRequirementTests.swift
//  PerfectNIOMySQLTests
//
//  The live tests skip when no server is configured, so a CI misconfiguration would pass
//  silently. With MYSQL_REQUIRE_LIVE=1 (set in CI wherever a server runs) this fails instead.
//

import Foundation
import Testing
import PerfectCRUD
import PerfectMySQL

struct LiveServerRequirementTests {
	static let required = ProcessInfo.processInfo.environment["MYSQL_REQUIRE_LIVE"] == "1"

	@Test(.enabled(if: required))
	func liveServerIsReachableWhenRequired() throws {
		#expect(MySQLTestEnvironment.skipReason == nil, "\(MySQLTestEnvironment.skipReason ?? "")")
		try #require(MySQLTestEnvironment.isEnabled)
		try MySQLTestEnvironment.ensureDatabase()
		let db = Database(configuration: try MySQLTestEnvironment.configuration())
		try db.sql("SELECT 1")
	}
}
