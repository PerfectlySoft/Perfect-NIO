
import PerfectCRUD
import PerfectNIO
import NIO

let big2048 = String(repeating: "A", count: 2048)
let big8192 = String(repeating: "A", count: 8192)
let big32768 = String(repeating: "A", count: 32768)

let prefix = "abc"

func printTupes(_ t: QueryDecoder) {
	for c in "abcdefghijklmnopqrstuvwxyz" {
		let key = prefix + String(c)
		let _ = t.get(key)
		//				print(fnd)
	}
}

checkCRUDRoutes()

let dataRoutes = try root().GET.dir {[
	$0.empty { "" },
	$0.2048 { big2048 },
	$0.8192 { big8192 },
	$0.32768 { big32768 },
]}

let argsRoutes: Routes<HTTPRequest, String> = try root().dir {[
	$0.GET.getArgs2048 {
		if let qd = $0.searchArgs {
			printTupes(qd)
		}
		return big2048
	},
	try $0.POST.dir{[
		$0.postArgs2048.readBody {
			if case .urlForm(let params) = $1 {
				printTupes(params)
			}
			return big2048
		},
		$0.postArgsMulti2048.readBody {
			if case .multiPartForm(let reader) = $1 {
				for c in "abcdefghijklmnopqrstuvwxyz" {
					let key = prefix + String(c)
					let _ = reader.bodySpecs.first { $0.fieldName == key }.map { $0.fieldValue }
					// print(fnd)
				}
			}
			return big2048
		},
	]}
]}

let jsonRoute = root().POST.path("json").decode(CRUDUser.self).json()

let create = root().POST.create.decode(CRUDUser.self).db(try crudDB()) {
	(user: CRUDUser, db: Database<SQLite>) throws -> CRUDUser in
	try db.sql("BEGIN IMMEDIATE")
	try db.table(CRUDUser.self).insert(user)
	try db.sql("COMMIT")
	return user
}.json()
let read = root().GET.read.wild {$1}.db(try crudDB()) {
	id, db throws -> CRUDUser in
	guard let user = try db.table(CRUDUser.self).where(\CRUDUser.id == id).first() else {
		throw HTTPOutputError(status: .notFound)
	}
	return user
}.json()
let update = root().POST.update.decode(CRUDUser.self).db(try crudDB()) {
	user, db throws -> CRUDUser in
	try db.sql("BEGIN IMMEDIATE")
	try db.table(CRUDUser.self).where(\CRUDUser.id == user.id).update(user)
	try db.sql("COMMIT")
	return user
}.json()
let delete = root().POST.delete.decode(CRUDUserRequest.self).db(try crudDB()) {
	req, db throws -> CRUDUserRequest in
	try db.sql("BEGIN IMMEDIATE")
	try db.table(CRUDUser.self).where(\CRUDUser.id == req.id).delete()
	try db.sql("COMMIT")
	return req
}.json()

let crudUserRoutes: Routes<HTTPRequest, HTTPOutput> =
	try root()
		.statusCheck { crudRoutesEnabled ? .ok : .internalServerError }
		.user
		.dir(
			create,
			read,
			update,
			delete)

let routes: Routes<HTTPRequest, HTTPOutput> = try root()
//	.then { print($0.uri) ; return $0 }
	.dir(dataRoutes.text(),
		 argsRoutes.text(),
		 jsonRoute,
		 crudUserRoutes)
#if os(Linux)
let count = System.coreCount
#else
let count = 1
#endif

let servers = try routes.bind(count: count, port: 9000).map { try $0.listen() }
print("Server listening on port 9000 with \(System.coreCount) cores")
try servers.forEach { try $0.wait() }
