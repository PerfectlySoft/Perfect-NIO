
import PerfectCRUD
import PerfectNIO
import NIO
import NIOOpenSSL

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
		throw ErrorOutput(status: .notFound, description: "Not found.")
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

/*
let serverCert = try! OpenSSLCertificate(buffer:
	Array("""
-----BEGIN CERTIFICATE-----
MIICpDCCAYwCCQCW58Rktc4bnjANBgkqhkiG9w0BAQUFADAUMRIwEAYDVQQDDAkx
MjcuMC4wLjEwHhcNMTgwMzE2MTM1MzI1WhcNMTgwNDE1MTM1MzI1WjAUMRIwEAYD
VQQDDAkxMjcuMC4wLjEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDX
TJ3iM/BWQy+jYQbZhyPaIcLVt/a7g2eaKtE55aiGXovbSXmpgfCi4TuyrmT+I8wJ
6bv668LaDZcNLhBP6ad7rtnVGorCJNqT845//+ghN75Y7oYi7+0Jx7ctKmizQ+b7
tyfozlMXn1al6kIpdVe3yKuzpzvBz/Vxj+UA88R3kn1QErPRbmcDYYp0LQUHSwn9
KzOkScr+lbn9q/b1gr9bV6afts5Xzyo7mBwk0yQTKCcVAuoveuufq1DB6dcGHN36
/stfT3EX65pK2Rdn1bFHVBJr4sGRCqlV5sn6cOwfl5yiSvLlgeqR7XqQjUZWwMg8
mfzeiDzZoVgy8+BAvb21AgMBAAEwDQYJKoZIhvcNAQEFBQADggEBAJ55mM4IiNLs
Tr096FOsTVmlXw1OANt03ClVqQlXAS1b5eWMTXwqJFoRex5UzucFoW7M375QpCT4
ei1F8GlXlybx8P7uYOGfvXYU2NFenmAIEHhzsx9LJRfPdb/IGgGfr9TfyIngVc9K
8OFPTbvBWIONeao3z9r0v4eXRtdnLn/7Qk+o6mTvlNe6IJsAcXWreqcfrzvAOwXD
7xmtwEs1C6EPrgA/GJq3QhD/HDkVxUyjQbc75HU+Ze8zecvoNsBvpRswg9BKa9xl
hU4SF5sARed3pySfEhoGAQD7N24QZX8uYo6/DqpBNJ48oJuDQh6mbwmpzise3gRx
8QvZfOf/dSY=
-----END CERTIFICATE-----
""".utf8).map{Int8($0)}, format: .pem)

let serverKey = try! OpenSSLPrivateKey(buffer:
	Array("""
-----BEGIN RSA PRIVATE KEY-----
MIIEpQIBAAKCAQEA10yd4jPwVkMvo2EG2Ycj2iHC1bf2u4NnmirROeWohl6L20l5
qYHwouE7sq5k/iPMCem7+uvC2g2XDS4QT+mne67Z1RqKwiTak/OOf//oITe+WO6G
Iu/tCce3LSpos0Pm+7cn6M5TF59WpepCKXVXt8irs6c7wc/1cY/lAPPEd5J9UBKz
0W5nA2GKdC0FB0sJ/SszpEnK/pW5/av29YK/W1emn7bOV88qO5gcJNMkEygnFQLq
L3rrn6tQwenXBhzd+v7LX09xF+uaStkXZ9WxR1QSa+LBkQqpVebJ+nDsH5ecokry
5YHqke16kI1GVsDIPJn83og82aFYMvPgQL29tQIDAQABAoIBAQDBSeqwyvppJ3Zc
Ul6I6leYnRjDMJ6VZ/qaIPin5vPudnFPFN7h/GNih51F5GWM9+xVtf7q3cCYbP0A
eytv4xBW7Ppp5KNQey+1BkMXzVLEh7wfMT1Bnm8Lib59EQbgcgSsVZnB24IjwgxT
dkWh3NQ8ji8AYhI3BRGQu6PXwAHRag+eLwWmHaaXGfXgDUerCPC2I7oNcix/payK
rfEztEesjT54ByICewAqusRyByWXEc3Hm6qayc0uGR8UzfRfL3Q2g9arKKDH8Kob
374ponjL1OWv/FI9EauhLsdRxnjeIeHZSX3WQPjEnp8odAvCcdf/nMJClNQw2zXw
t80ytYgBAoGBAPVJXjtSzNP3ZIXDIx0VMucIdrcMJhiGu3qUtCyrBsKe9W6IaDZd
7eJ8hvKV2Y7ycIUv17X227PbL8uqMVe855ALbidIQuFV1mqTO8dJeNiqbqfi42aL
xyeHKW9+rdiDi55GEQgNeCSUd8VHO/DdcfCneuvKDgWo3QtzzfcyfUIBAoGBAOCz
81Ad4qHDVButh/bro5vsEP4Xq7SVYuqPQBQKwMm78LJtUcLSdbmYjEKakDzZbuAl
xl5Zl5LBkgOIfEmJk+XbBy3NvNsUioGza7hWKD2aSo6s0tgDtfYmUta038t2gwdH
ccHyERQhq+e8Z7x8cCWp48axmbfEtBoVejuySBO1AoGBAOtVryE/ueGMtFdZ97CJ
jEL5bd0FvO8/JVTgo1VP6baEiHm6SjIPQJNSYq8QcqGhna9LTaz54aTYIS1IZvsE
9S7QqKjrva8wif3KsUntBhLqwiw1lXPnm/YiyfB9HBJlc2kxVFnjgmemQpt2Ut4v
uIfqSBc9zuJDN4ErZGtNd7wBAoGBAL/9gVtm7YlBl8++SXnUhIpo/WvdVbyKF2ZK
13lIZsj3aAVMGpvXrvbRPKZ74dnb/jxOilt7OWMPOW8DYw6CGng+2LduHnsh5eZE
Iznxg5h/CE03pT8kjIiw3f7NtJnnvLSveqc36RfGXVc3R3to53mG2zOd87VswGW5
DCONhMAxAoGAaokOEY3wwEK34KOWDRrAEpMH5DQagecCB3L+QclkdratcqtGIt62
Z8TvyV3f6Wl89pcpI1y5RZm8cbUF2rvlHjJ8WLSBEcR5vFnRCOplAQZdmg9Tmv/6
toWGTsOXMHUr1s3T2Lh4UtWW+kMSNU16Es+DcGP2Rq3VJ3juuywdkCQ=
-----END RSA PRIVATE KEY-----
""".utf8).map{Int8($0)}, format: .pem)

let route = root { "OK" }.text()
let tls = TLSConfiguration.forServer(
	certificateChain: [.certificate(serverCert)],
	privateKey: .privateKey(serverKey))
let server = try route.bind(port: 42000, tls: tls).listen()
try server.wait()
*/

