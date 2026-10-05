//
//  MySQLTestEnvironment.swift
//  PerfectNIOMySQLTests
//
//  Live-server settings shared by the MySQL tests, read from the same
//  environment variable names as Perfect-MySQL's own suite (but stricter
//  about the port and host -- see below):
//
//    MYSQL_TESTS=1                 enable the live tests
//    MYSQL_TEST_PORT               required, 1...65535 -- there is no default
//    MYSQL_TEST_HOST               default 127.0.0.1; "localhost" is refused
//    MYSQL_TEST_USER               default root
//    MYSQL_TEST_PASSWORD           default empty
//    MYSQL_TEST_DATABASE           default test (created if missing)
//    MYSQL_TEST_ADMIN_DATABASE     default mysql (used to create the above)
//
//  Live tests are skipped unless MYSQL_TESTS=1, MYSQL_TEST_PORT is a valid
//  port and the host isn't "localhost". Falling back to the client's default
//  port (3306, which libmysql also uses for port 0) would point drop-and-
//  recreate tests at whatever MySQL server happens to be running locally,
//  and libmysql reaches "localhost" through the Unix socket, ignoring the
//  port entirely.
//

import Foundation
import PerfectCRUD
import PerfectMySQL

enum MySQLTestEnvironment {
	private static let env = ProcessInfo.processInfo.environment

	static let host = env["MYSQL_TEST_HOST"] ?? "127.0.0.1"
	static let port = env["MYSQL_TEST_PORT"].flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil }
	static let user = env["MYSQL_TEST_USER"] ?? "root"
	static let password = env["MYSQL_TEST_PASSWORD"] ?? ""
	static let database = env["MYSQL_TEST_DATABASE"] ?? "test"
	static let adminDatabase = env["MYSQL_TEST_ADMIN_DATABASE"] ?? "mysql"

	/// True only when MYSQL_TESTS=1, MYSQL_TEST_PORT is a valid port and the
	/// host isn't "localhost".
	static var isEnabled: Bool { skipReason == nil }

	/// Why live tests are skipped, or nil when they are enabled.
	static var skipReason: String? {
		if env["MYSQL_TESTS"] != "1" { return "set MYSQL_TESTS=1 to enable live MySQL tests" }
		if port == nil { return "set MYSQL_TEST_PORT to a test server's port, 1...65535 (3306 is never assumed)" }
		if host.lowercased() == "localhost" {
			return "MYSQL_TEST_HOST=localhost uses the Unix socket and ignores the port; use 127.0.0.1"
		}
		return nil
	}

	/// A connection to `database` on the configured test server.
	/// Call only when `isEnabled`; otherwise this could reach a server on 3306.
	static func configuration(database: String = database) throws -> MySQLDatabaseConfiguration {
		precondition(isEnabled, "MySQLTestEnvironment.configuration() called while disabled: \(skipReason ?? "")")
		return try MySQLDatabaseConfiguration(database: database, host: host, port: port,
											  username: user, password: password)
	}

	/// Creates the test database if it doesn't exist. A stock mysql:8.4
	/// container has no "test" schema, and connecting straight to a missing
	/// database fails.
	static func ensureDatabase() throws {
		try Database(configuration: configuration(database: adminDatabase))
			.sql("CREATE DATABASE IF NOT EXISTS `\(database.replacingOccurrences(of: "`", with: "``"))`")
	}
}
