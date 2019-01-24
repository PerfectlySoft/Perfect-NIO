import XCTest
import NIOHTTP1
import NIO
import NIOOpenSSL
import PerfectCRUD
import PerfectSQLite
import PerfectCURL
@testable import PerfectNIO

protocol APIResponse: Codable {}
let userCount = 10

final class PerfectNIOTests: XCTestCase {
	
	func testRoot1() {
		do {
			let route = root { "OK" }.text()
			let server = try route.bind(port: 42000).listen()
			let req = try CURLRequest("http://localhost:42000/").perform()
			XCTAssertEqual(req.bodyString, "OK")
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	func testRoot2() {
		do {
			let route1 = root { "OK2" }.text()
			let route2 = root { "OK1" }.foo { $0 }.text()
			let server = try root().dir(route1, route2).bind(port: 42000).listen()
			let resp1 = try CURLRequest("http://localhost:42000/foo").perform().bodyString
			XCTAssertEqual(resp1, "OK1")
			let resp2 = try CURLRequest("http://localhost:42000/").perform().bodyString
			XCTAssertEqual(resp2, "OK2")
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	func testDir1() {
		do {
			let route = try root().dir{[
				$0.foo1 { "OK1" },
				$0.foo2 { "OK2" },
				$0.foo3 { "OK3" },
				]}.text()
			let server = try route.bind(port: 42000).listen()
			let resp1 = try CURLRequest("http://localhost:42000/foo1").perform().bodyString
			XCTAssertEqual(resp1, "OK1")
			let resp2 = try CURLRequest("http://localhost:42000/foo2").perform().bodyString
			XCTAssertEqual(resp2, "OK2")
			let resp3 = try CURLRequest("http://localhost:42000/foo3").perform().bodyString
			XCTAssertEqual(resp3, "OK3")
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	func testDuplicates() {
		do {
			let route = try root().dir{[
				$0.foo1 { "OK1" },
				$0.foo1 { "OK2" },
				$0.foo3 { "OK3" },
				]}.text()
			let server = try route.bind(port: 42000).listen()
			try server.stop().wait()
			XCTAssert(false)
		} catch {
			XCTAssert(true)
		}
	}
	func testUriVars() {
		struct Req: Codable {
			let id: UUID
			let action: String
		}
		do {
			let route = root().v1
				.wild(name: "id")
				.wild(name: "action")
				.decode(Req.self) { return "\($1.id) - \($1.action)" }
				.text()
			let id = UUID().uuidString
			let action = "share"
			let uri1 = "/v1/\(id)/\(action)"
			let server = try route.bind(port: 42000).listen()
			let resp1 = try CURLRequest("http://localhost:42000\(uri1)").perform().bodyString
			XCTAssertEqual(resp1, "\(id) - \(action)")
			try server.stop().wait()
		} catch {
			XCTAssert(true)
		}
	}
	func testWildCard() {
		do {
			let route = root().wild { $1 }.foo.text()
			let server = try route.bind(port: 42000).listen()
			let req = try CURLRequest("http://localhost:42000/OK/foo").perform()
			XCTAssertEqual(req.bodyString, "OK")
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	func testTrailingWildCard() {
		do {
			let route = root().foo.trailing { $1 }.text()
			let server = try route.bind(port: 42000).listen()
			let req = try CURLRequest("http://localhost:42000/foo/OK/OK").perform()
			XCTAssertEqual(req.bodyString, "OK/OK")
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	func testMap1() {
		do {
			let route = try root().dir {[
				$0.a { 1 }.map { "\($0)" }.text(),
				$0.b { [1,2,3] }.map { (i: Int) -> String in "\(i)" }.json()
			]}
			let server = try route.bind(port: 42000).listen()
			let req1 = try CURLRequest("http://localhost:42000/a").perform()
			XCTAssertEqual(req1.bodyString, "1")
			let req2 = try CURLRequest("http://localhost:42000/b").perform().bodyJSON(Array<String>.self)
			XCTAssertEqual(req2, ["1","2","3"])
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	func testStatusCheck1() {
		do {
			let route = try root().dir {[
				$0.a.statusCheck { .internalServerError }.map { "BAD" }.text(),
				$0.b.statusCheck { _ in .internalServerError }.map { "BAD" }.text(),
				$0.c.statusCheck { _ in .ok }.map { "OK" }.text()
				]}
			let server = try route.bind(port: 42000).listen()
			let req1 = try CURLRequest("http://localhost:42000/a").perform()
			XCTAssertEqual(req1.responseCode, 500)
			let req2 = try CURLRequest("http://localhost:42000/b").perform()
			XCTAssertEqual(req2.responseCode, 500)
			let req3 = try CURLRequest("http://localhost:42000/c").perform().bodyString
			XCTAssertEqual(req3, "OK")
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	func testMethods1() {
		do {
			let route = try root().dir {[
				$0.GET.foo1 { "GET OK" },
				$0.POST.foo2 { "POST OK" },
				]}.text()
			let server = try route.bind(port: 42000).listen()
			let req1 = try CURLRequest("http://localhost:42000/foo1").perform().bodyString
			XCTAssertEqual(req1, "GET OK")
			let req2 = try CURLRequest("http://localhost:42000/foo2", .postString("")).perform().bodyString
			XCTAssertEqual(req2, "POST OK")
			let req3 = try CURLRequest("http://localhost:42000/foo1", .postString("")).perform().responseCode
			XCTAssertEqual(req3, 404)
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	func testReadBody1() {
		do {
			let route = try root().dir(type: String.self) {[
				$0.multi.readBody {
					req, cont in
					switch cont {
					case .multiPartForm(_):
						return "OK"
					case .none, .urlForm, .other:
						throw ErrorOutput(status: .badRequest)
					}
				},
				$0.url.readBody {
					req, cont in
					switch cont {
					case .urlForm(_):
						return "OK"
					case .none, .multiPartForm, .other:
						throw ErrorOutput(status: .badRequest)
					}
				},
				$0.other.readBody {
					req, cont in
					switch cont {
					case .other(_):
						return "OK"
					case .none, .multiPartForm, .urlForm:
						throw ErrorOutput(status: .badRequest)
					}
				},
			]}.POST.text()
			let server = try route.bind(port: 42000).listen()
			let req1 = try CURLRequest("http://localhost:42000/multi", .postField(.init(name: "foo", value: "bar"))).perform().bodyString
			XCTAssertEqual(req1, "OK")
			let req2 = try CURLRequest("http://localhost:42000/url", .postString("foo=bar")).perform().bodyString
			XCTAssertEqual(req2, "OK")
			let req3 = try CURLRequest("http://localhost:42000/other", .addHeader(.contentType, "application/octet-stream"), .postData([1,2,3,4,5])).perform().bodyString
			XCTAssertEqual(req3, "OK")
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	func testDecodeBody1() {
		struct Foo: Codable {
			let id: UUID
			let date: Date
		}
		do {
			let route = try root().POST.dir{[
				$0.1.decode(Foo.self),
				$0.2.decode(Foo.self) { $1 },
				$0.3.decode(Foo.self) { $0 },
				]}.json()
			let server = try route.bind(port: 42000).listen()
			let foo = Foo(id: UUID(), date: Date())
			let fooData = Array(try JSONEncoder().encode(foo))
			for i in 1...3 {
				let req = try CURLRequest("http://localhost:42000/\(i)", .addHeader(.contentType, "application/json"), .postData(fooData)).perform().bodyJSON(Foo.self)
				XCTAssertEqual(req.id, foo.id)
				XCTAssertEqual(req.date, foo.date)
			}
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	func testPathExt1() {
		struct Foo: Codable, CustomStringConvertible {
			var description: String {
				return "foo-data \(id)/\(date)"
			}
			let id: UUID
			let date: Date
		}
		do {
			let fooRoute = root().foo { Foo(id: UUID(), date: Date()) }
			let route = try root().dir(
				fooRoute.ext("json").json(),
				fooRoute.ext("txt").text())
			let server = try route.bind(port: 42000).listen()
			let req1 = try? CURLRequest("http://localhost:42000/foo.json").perform().bodyJSON(Foo.self)
			XCTAssertNotNil(req1)
			let req2 = try CURLRequest("http://localhost:42000/foo.txt").perform().bodyString
			XCTAssert(req2.hasPrefix("foo-data "))
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	
	func testQueryDecoder() {
		let q = QueryDecoder(Array("a=1&b=2&c=3&d=4&b=5&e&f=&g=1234567890&h".utf8))
		XCTAssertEqual(q["not"], [])
		XCTAssertEqual(q["a"], ["1"])
		XCTAssertEqual(q["b"], ["2", "5"])
		XCTAssertEqual(q["c"], ["3"])
		XCTAssertEqual(q["d"], ["4"])
		XCTAssertEqual(q["e"], [""])
		XCTAssertEqual(q["f"], [""])
		XCTAssertEqual(q["g"], ["1234567890"])
		XCTAssertEqual(q["h"], [""])
//		print("\(q.lookup)")
//		print("\(q.ranges)")
	}
	func testQueryDecoderSpeed() {
		func printTupes(_ t: QueryDecoder) {
			for c in "abcdefghijklmnopqrstuvwxyz" {
				let key = "abc" + String(c)
				let _ = t.get(key)
				//				print(fnd)
			}
		}
		let body = Array("abca=abcdefghijklmnopqrstuvwxyz&abcb=abcdefghijklmnopqrstuvwxyz&abcc=abcdefghijklmnopqrstuvwxyz&abcd=abcdefghijklmnopqrstuvwxyz&abce=abcdefghijklmnopqrstuvwxyz&abcf=abcdefghijklmnopqrstuvwxyz&abcg=abcdefghijklmnopqrstuvwxyz&abch=abcdefghijklmnopqrstuvwxyz&abci=abcdefghijklmnopqrstuvwxyz&abcj=abcdefghijklmnopqrstuvwxyz&abck=abcdefghijklmnopqrstuvwxyz&abcl=abcdefghijklmnopqrstuvwxyz&abcm=abcdefghijklmnopqrstuvwxyz&abcn=abcdefghijklmnopqrstuvwxyz&abco=abcdefghijklmnopqrstuvwxyz&abcp=abcdefghijklmnopqrstuvwxyz&abcq=abcdefghijklmnopqrstuvwxyz&abca=abcdefghijklmnopqrstuvwxyz&abcs=abcdefghijklmnopqrstuvwxyz&abct=abcdefghijklmnopqrstuvwxyz&abcu=abcdefghijklmnopqrstuvwxyz&abcv=abcdefghijklmnopqrstuvwxyz&abcw=abcdefghijklmnopqrstuvwxyz&abcx=abcdefghijklmnopqrstuvwxyz&abcy=abcdefghijklmnopqrstuvwxyz&abcz=abcdefghijklmnopqrstuvwxyz".utf8)
		self.measure {
			for _ in 0..<20000 {
				let q = QueryDecoder(body)
				printTupes(q)
			}
		}
	}
	
	func testTLS1() {
		do {
			let route = root { "OK" }.text()
			let tls = TLSConfiguration.forServer(
				certificateChain: [.certificate(serverCert)],
				privateKey: .privateKey(serverKey))
			let server = try route.bind(port: 42000, tls: tls).listen()
			let req1 = try CURLRequest("https://localhost:42000/", .sslVerifyPeer(false), .sslVerifyHost(false)).perform().bodyString
			XCTAssertEqual(req1, "OK")
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	
	func testGetRequest1() {
		do {
			let route = root().foo { "OK" }.request { $1.path }.text()
			let server = try route.bind(port: 42000).listen()
			let req1 = try CURLRequest("http://localhost:42000/foo").perform().bodyString
			XCTAssertEqual(req1, "/foo")
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	
	func testAsync1() {
		do {
			let route = root().async {
				(req: HTTPRequest, p: EventLoopPromise<String>) in
				sleep(1)
				p.succeed(result: "OK")
				}.text()
			let server = try route.bind(port: 42000).listen()
			let req1 = try CURLRequest("http://localhost:42000/").perform().bodyString
			XCTAssertEqual(req1, "OK")
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	
	func testAsync2() {
		struct MyError: Error {}
		do {
			let route = root().async {
				(req: HTTPRequest, p: EventLoopPromise<String>) in
				sleep(1)
				p.fail(error: MyError())
				}.text()
			let server = try route.bind(port: 42000).listen()
			defer { try! server.stop().wait() }
			_ = try CURLRequest("http://localhost:42000/", .failOnError).perform()
			XCTAssert(false)
		} catch {
			XCTAssert(true)
		}
	}
	
//	func testStream() {
//		do {
//			let route = root().stream {
//				req, token in
//				do {
//					for i in 0..<16 {
//						let toSend = String(repeating: "\(i % 10)", count: 1024)
//						try token.push(Array(toSend.utf8))
//					}
//					token.complete()
//				} catch {
//					token.fail(error: error)
//				}
//			}
//			let server = try route.bind(port: 42000).listen()
//			let req = try CURLRequest("http://localhost:42000/").perform()
//			XCTAssertEqual(req.bodyString.count, 16384)
//			try server.stop().wait()
//		} catch {
//			XCTFail("\(error)")
//		}
//	}
	
	func testCompress1() {
		do {
			let route = root() {
				var bytes: [UInt8] = []
				for i in 0..<16 {
					let toSend = String(repeating: "\(i % 10)", count: 1024)
					bytes.append(contentsOf: Array(toSend.utf8))
				}
				return BytesOutput(body: bytes)
			}.compressed()
			let server = try route.bind(port: 42000).listen()
			let req = try CURLRequest("http://localhost:42000/", .acceptEncoding("gzip, deflate")).perform()
			XCTAssertEqual(req.bodyString.count, 16384)
			XCTAssert(req.headers.contains(where: { $0.0 == .contentEncoding && $0.1 == "gzip" }))
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	
	func testUnwrap() {
		do {
			let route = try root().dir {[
				$0.a { nil },
				$0.b { "OK" }
				]}.unwrap { $0 }.text()
			let server = try route.bind(port: 42000).listen()
			let req1 = try CURLRequest("http://localhost:42000/b").perform().bodyString
			XCTAssertEqual(req1, "OK")
			let req2 = try CURLRequest("http://localhost:42000/a").perform()
			XCTAssertEqual(req2.responseCode, 500)
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	
	func testAuthEg() {
		//let userCount = 10
		//protocol APIResponse {} - protocol can't be nested. real thing is up top ^
		struct AuthenticatedRequest {
			init?(_ request: HTTPRequest) {
				// would check auth and return nil if invalid
			}
		}
		struct User: Codable, APIResponse {
			let id: UUID
		}
		struct FriendList: Codable, APIResponse {
			let users: [User]
		}
		struct AppHandlers {
			static func userInfo(user: User) -> User {
				// just echo it back
				return user
			}
			static func friendList(for user: User) -> FriendList {
				// make up some friends
				return FriendList(users: (0..<userCount).map { _ in User(id: UUID()) })
			}
		}
		
		let authenticatedRoute = root(AuthenticatedRequest.init)
			.statusCheck { $0 == nil ? .unauthorized : .ok }
			.unwrap { $0 }
		
		do {
			let v1Routes = try authenticatedRoute
				.wild(name: "id")
				.decode(User.self)
				.dir {[
					$0.info(AppHandlers.userInfo).json(),
					$0.friends(AppHandlers.friendList).json()
				]}
			let server = try v1Routes.bind(port: 42000).listen()
			let uuid = UUID()
			let req = try CURLRequest("http://localhost:42000/\(uuid.uuidString)/info").perform().bodyJSON(User.self)
			XCTAssertEqual(req.id, uuid)
			let req2 = try CURLRequest("http://localhost:42000/\(uuid.uuidString)/friends").perform().bodyJSON(FriendList.self)
			XCTAssertEqual(req2.users.count, userCount)
			try server.stop().wait()
		} catch {
			XCTFail("\(error)")
		}
	}
	
    static var allTests = [
		("testRoot1", testRoot1),
		("testRoot2", testRoot2),
		("testDir1", testDir1),
		("testDuplicates", testDuplicates),
		("testUriVars", testUriVars),
		("testWildCard", testWildCard),
		("testTrailingWildCard", testTrailingWildCard),
		("testMap1", testMap1),
		("testStatusCheck1", testStatusCheck1),
		("testMethods1", testMethods1),
		("testReadBody1", testReadBody1),
		("testDecodeBody1", testDecodeBody1),
		("testPathExt1", testPathExt1),
		("testQueryDecoder", testQueryDecoder),
		("testQueryDecoderSpeed", testQueryDecoderSpeed),
		("testTLS1", testTLS1),
		("testGetRequest1", testGetRequest1),
		("testAsync1", testAsync1),
		("testAsync2", testAsync2),
//		("testStream", testStream),
		("testUnwrap", testUnwrap),
		("testAuthEg", testAuthEg),
		("testQueryDecoder", testQueryDecoder),
    ]
}

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
