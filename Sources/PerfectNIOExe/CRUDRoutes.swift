//
//  CRUDRoutes.swift
//  PerfectHTTPCRUDExe
//
//  Created by Kyle Jessup on 2018-11-01.
//

import PerfectCRUD
import PerfectSQLite

// This is only here for CENGN testing
// main HTTPCRUDLib will be moved to real repo

var crudRoutesEnabled = false

let dbHost = "localhost"
let dbName = "postgresdb"
let dbUser = "postgresuser"
let dbPassword = "postgresuser"

typealias SQLite = SQLiteDatabaseConfiguration

func crudTable<T: Codable>(_ t: T.Type) throws -> Table<T, Database<SQLite>> {
	return try crudDB().table(t)
}
func crudDB() throws -> Database<SQLite> {
	let db = Database(configuration:
		try SQLite("file::memory:?cache=shared&mode=rwc"))
	try db.sql("PRAGMA journal_mode=WAL;")
	try db.sql("PRAGMA synchronous = NORMAL;")
	return db
}

struct CRUDUser: Codable {
	let id: String
	let firstName: String
	let lastName: String
}

struct CRUDUserRequest: Codable {
	let id: String
}

fileprivate var holdIt: Database<SQLite>?

func checkCRUDRoutes() {
	CRUDLogging.queryLogDestinations = []
	do {
		holdIt = try crudDB()
		try holdIt?.create(CRUDUser.self, primaryKey: \.id).index(\.firstName, \.lastName)
		try holdIt?.sql("PRAGMA busy_timeout = 600000")
		crudRoutesEnabled = true
		print("CRUD routes enabled.")
	} catch {
		crudRoutesEnabled = false
		print("No database connection. CRUD routes disabled.")
	}
}
