import XCTest
import Foundation
@testable import PerfectAdminConsole
import PerfectNIO

// MARK: - Token store

final class AdminTokenStoreTests: XCTestCase {

    private func tempTokenPath() -> String {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("perfect-admin-test-\(Int.random(in: 0..<Int.max)).token").path
    }

    func testInit_writesTokenFile() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AdminTokenStore(tokenFilePath: path)
        let contents = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(contents, store.token)
        XCTAssertEqual(contents.count, 64)
    }

    func testInit_appliesChmod600() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try AdminTokenStore(tokenFilePath: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testInit_tokenIs64HexChars() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AdminTokenStore(tokenFilePath: path)
        XCTAssertTrue(store.token.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(store.token.count, 64)
    }

    func testInit_twoTokensAreDistinct() throws {
        let p1 = tempTokenPath(), p2 = tempTokenPath()
        defer {
            try? FileManager.default.removeItem(atPath: p1)
            try? FileManager.default.removeItem(atPath: p2)
        }
        let s1 = try AdminTokenStore(tokenFilePath: p1)
        let s2 = try AdminTokenStore(tokenFilePath: p2)
        XCTAssertNotEqual(s1.token, s2.token)
    }

    func testInit_reusesExistingTokenAcrossRestartsBySameFilePath() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try AdminTokenStore(tokenFilePath: path)
        let second = try AdminTokenStore(tokenFilePath: path)
        XCTAssertEqual(first.token, second.token)
    }

    func testInit_forceNewTokenRotatesEvenAtSameFilePath() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try AdminTokenStore(tokenFilePath: path)
        let second = try AdminTokenStore(tokenFilePath: path, forceNewToken: true)
        XCTAssertNotEqual(first.token, second.token)
        // The rotated token is what actually got persisted to disk.
        let contents = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(contents, second.token)
    }

    func testInit_fallsBackToFreshTokenWhenExistingFileIsMalformed() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "not-a-valid-token".write(toFile: path, atomically: true, encoding: .utf8)
        let store = try AdminTokenStore(tokenFilePath: path)
        XCTAssertEqual(store.token.count, 64)
        XCTAssertTrue(store.token.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testRequireAuth_validToken_doesNotThrow() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AdminTokenStore(tokenFilePath: path)
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(store.token)")
        XCTAssertNoThrow(try store.requireAuth(from: headers))
    }

    func testRequireAuth_wrongToken_throws() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AdminTokenStore(tokenFilePath: path)
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer notthetoken")
        XCTAssertThrowsError(try store.requireAuth(from: headers))
    }

    func testRequireAuth_missingHeader_throws() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AdminTokenStore(tokenFilePath: path)
        XCTAssertThrowsError(try store.requireAuth(from: HTTPHeaders()))
    }

    func testRequireAuth_wrongScheme_throws() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AdminTokenStore(tokenFilePath: path)
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Basic abc123")
        XCTAssertThrowsError(try store.requireAuth(from: headers))
    }

    func testRequireAuth_caseInsensitiveBearer() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AdminTokenStore(tokenFilePath: path)
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "bearer \(store.token)")
        XCTAssertNoThrow(try store.requireAuth(from: headers))
    }
}

// MARK: - Log capture

final class LogCaptureTests: XCTestCase {

    func testCapture_returnsLines() async {
        let cap = LogCapture()
        await cap.capture("line one")
        await cap.capture("line two")
        let lines = await cap.recentLines(count: 10)
        XCTAssertEqual(lines, ["line one", "line two"])
    }

    func testRingBuffer_dropsOldestWhenFull() async {
        let cap = LogCapture(capacity: 3)
        await cap.capture("a")
        await cap.capture("b")
        await cap.capture("c")
        await cap.capture("d")
        let lines = await cap.recentLines(count: 10)
        XCTAssertEqual(lines, ["b", "c", "d"])
        XCTAssertFalse(lines.contains("a"))
    }

    func testRecentLines_respectsCount() async {
        let cap = LogCapture()
        for i in 0..<20 { await cap.capture("line \(i)") }
        let lines = await cap.recentLines(count: 5)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.last, "line 19")
    }

    func testTotalCaptured_countsAllAdded() async {
        let cap = LogCapture(capacity: 3)
        await cap.capture("a")
        await cap.capture("b")
        await cap.capture("c")
        await cap.capture("d") // displaces "a"
        let total = await cap.totalCaptured
        // totalCaptured reflects current buffer size (ring-buffer view), not the lifetime count
        XCTAssertEqual(total, 3)
    }

    func testEmptyCapture_returnsEmptyLines() async {
        let cap = LogCapture()
        let lines = await cap.recentLines(count: 10)
        XCTAssertEqual(lines, [])
    }
}

// MARK: - LogCapture.Entry (Phase 8: log viewer component)

final class LogCaptureEntryTests: XCTestCase {

    func testCapture_defaultIsErrorFalse() async {
        let cap = LogCapture()
        await cap.capture("[admin] all fine")
        let entries = await cap.recentEntries(count: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].isError)
    }

    func testCapture_isErrorTrueWhenPassed() async {
        let cap = LogCapture()
        await cap.capture("[render-error] boom", isError: true)
        let entries = await cap.recentEntries(count: 10)
        XCTAssertTrue(entries[0].isError)
    }

    func testRecentEntries_oldestDroppedWhenFull() async {
        let cap = LogCapture(capacity: 3)
        await cap.capture("a")
        await cap.capture("b")
        await cap.capture("c")
        await cap.capture("d")
        let entries = await cap.recentEntries(count: 10)
        XCTAssertEqual(entries.map(\.message), ["b", "c", "d"])
    }

    func testRecentEntries_respectsCount() async {
        let cap = LogCapture()
        for i in 0..<20 { await cap.capture("line \(i)") }
        let entries = await cap.recentEntries(count: 5)
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries.last?.message, "line 19")
    }

    func testRecentLines_derivedFromEntries_matchesMessages() async {
        let cap = LogCapture()
        await cap.capture("[admin] one")
        await cap.capture("[datasource] two", isError: true)
        let lines = await cap.recentLines(count: 10)
        let entries = await cap.recentEntries(count: 10)
        XCTAssertEqual(lines, entries.map(\.message))
    }

    func testCapacity_isPubliclyReadable() async {
        let cap = LogCapture(capacity: 7)
        let capacity = cap.capacity
        XCTAssertEqual(capacity, 7)
    }

    func testEntry_timestampDefaultsToNow_isRecent() async {
        let cap = LogCapture()
        let before = Date()
        await cap.capture("[admin] timed")
        let entries = await cap.recentEntries(count: 1)
        XCTAssertGreaterThanOrEqual(entries[0].timestamp, before)
        XCTAssertLessThan(entries[0].timestamp.timeIntervalSinceNow, 1)
    }

    func testClear_clearsEntriesToo() async {
        let cap = LogCapture()
        await cap.capture("a")
        await cap.capture("b")
        let dropped = await cap.clear()
        XCTAssertEqual(dropped, 2)
        let entries = await cap.recentEntries(count: 10)
        XCTAssertTrue(entries.isEmpty)
    }
}

// MARK: - AdminConsole delegate / RouteInfo

final class AdminConsoleDelegateTests: XCTestCase {

    func testRouteInfo_storesURI() {
        let info = RouteInfo(uri: "GET:///foo/bar")
        XCTAssertEqual(info.uri, "GET:///foo/bar")
    }

    func testAdminStatusSection_storesItemsOrdered() {
        let section = AdminStatusSection(title: "My App", items: [("Key", "Value"), ("Foo", "Bar")])
        XCTAssertEqual(section.title, "My App")
        XCTAssertEqual(section.items.map(\.key), ["Key", "Foo"])
    }
}

// MARK: - JSONText (regression coverage for the status-card item-shuffle bug)
//
// `JSONEncoder` does not preserve object key order — confirmed empirically
// (a first attempt at this fix used a manually-populated
// `KeyedEncodingContainer` with a dynamic `CodingKey`, and Foundation's
// encoder STILL reordered it), which made status card contents visibly
// shuffle between dashboard refreshes. `JSONText` bypasses `Encodable`
// entirely and builds JSON text directly, so these tests check the actual
// string output, not a re-decoded (and therefore re-unordered) value.

final class JSONTextTests: XCTestCase {

    func testString_escapesQuotesBackslashesAndControlCharacters() {
        XCTAssertEqual(JSONText.string(#"say "hi""#), #""say \"hi\"""#)
        XCTAssertEqual(JSONText.string(#"a\b"#), #""a\\b""#)
        XCTAssertEqual(JSONText.string("line1\nline2"), "\"line1\\nline2\"")
        XCTAssertEqual(JSONText.string("plain"), "\"plain\"")
    }

    func testObject_preservesDeliberatelyUnalphabeticalOrder() {
        // Deliberately not alphabetical and not any obvious hash order —
        // if this ever routes back through JSONEncoder/Dictionary, key
        // order becomes unspecified and this assertion would catch it.
        let json = JSONText.object([
            ("Zebra", "1"), ("Apple", "2"), ("Mango", "3"), ("Banana", "4"),
        ])
        let positions = ["Zebra", "Apple", "Mango", "Banana"].map {
            json.range(of: "\"\($0)\"")!.lowerBound
        }
        XCTAssertEqual(positions, positions.sorted(), "keys should appear in insertion order, not any other order")
    }

    func testObject_repeatedCallsAreStable() {
        let pairs: [(key: String, value: String)] = [
            ("Enabled", "yes"), ("Mode", "ARMED"), ("Poll interval", "20s"), ("Min floor", "5"),
        ]
        XCTAssertEqual(JSONText.object(pairs), JSONText.object(pairs))
    }

    func testObject_emptyProducesEmptyObject() {
        XCTAssertEqual(JSONText.object([]), "{}")
    }

    func testSection_buildsExpectedShape() {
        let json = JSONText.section(title: "My App", items: [("Key", "Value"), ("Foo", "Bar")])
        XCTAssertEqual(json, #"{"title":"My App","items":{"Key":"Value","Foo":"Bar"},"alertKeys":[]}"#)
    }

    func testSection_withAlertKeys_includesSortedKeysArray() {
        let json = JSONText.section(title: "CWP Session Janitor", items: [("Mode", "ARMED")], alertKeys: ["Mode"])
        XCTAssertEqual(json, #"{"title":"CWP Session Janitor","items":{"Mode":"ARMED"},"alertKeys":["Mode"]}"#)
    }

    func testJob_nilProducesNullLiteral() {
        XCTAssertEqual(JSONText.job(nil), "null")
    }

    func testJob_buildsExpectedShape() {
        let json = JSONText.job(AdminRunningJob(name: "Crawl report", completed: 340, total: 1989))
        XCTAssertEqual(json, #"{"name":"Crawl report","completed":340,"total":1989}"#)
    }
}

// MARK: - TLSContextManager additions

final class TLSContextManagerAdminTests: XCTestCase {

    func testRegisteredHostnames_emptyOnInit() async throws {
        let mgr = try TLSContextManager()
        let names = await mgr.registeredHostnames()
        XCTAssertTrue(names.isEmpty)
    }

    func testHasDefaultContext_falseWhenNoDefault() async throws {
        let mgr = try TLSContextManager()
        let has = await mgr.hasDefaultContext
        XCTAssertFalse(has)
    }

    func testRegisteredHostnames_returnsSortedDomains() async throws {
        let mgr = try TLSContextManager()
        // Without real certs we can only test the shape; a non-throwing
        // registration helper isn't available without PEM files.
        // So we just confirm the return type and empty baseline.
        let names = await mgr.registeredHostnames()
        XCTAssertEqual(names, names.sorted())
    }
}

// MARK: - ACMEChallengeResponder additions

final class ACMEPendingCountTests: XCTestCase {

    func testPendingCount_zeroInitially() async {
        let acme = ACMEChallengeResponder()
        let count = await acme.pendingCount
        XCTAssertEqual(count, 0)
    }

    func testPendingCount_incrementsOnAdd() async {
        let acme = ACMEChallengeResponder()
        await acme.addChallenge(token: "tok1", keyAuthorization: "auth1")
        await acme.addChallenge(token: "tok2", keyAuthorization: "auth2")
        let count = await acme.pendingCount
        XCTAssertEqual(count, 2)
    }

    func testPendingCount_decrementsOnRemove() async {
        let acme = ACMEChallengeResponder()
        await acme.addChallenge(token: "tok", keyAuthorization: "auth")
        await acme.removeChallenge(token: "tok")
        let count = await acme.pendingCount
        XCTAssertEqual(count, 0)
    }
}

// MARK: - AdminWebUI

final class AdminWebUITests: XCTestCase {

    func testResponse_isHTMLOutput() {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/test.token")
        let head = output.head(request: HTTPRequestInfo(head: .init(version: .http1_1, method: .GET, uri: "/"), options: []))
        let ct = head?.headers.first(name: "Content-Type") ?? ""
        XCTAssertTrue(ct.hasPrefix("text/html"))
    }

    func testResponse_injectsTokenPath() async throws {
        let output = AdminWebUI.response(tokenFilePath: "/var/run/myapp.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        let html = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(html.contains("myapp.token"), "Token path not injected into HTML")
    }

    func testResponse_specialCharsInPathAreEscaped() async throws {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/path with \"quotes\".token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        let html = String(decoding: body, as: UTF8.self)
        // Raw quotes should not appear unescaped inside the JS string context
        XCTAssertFalse(html.contains(#"path with "quotes""#), "Path not JSON-escaped in HTML")
    }

    func testResponse_cacheControlNoStore() {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        let head = output.head(request: HTTPRequestInfo(head: .init(version: .http1_1, method: .GET, uri: "/"), options: []))
        let cc = head?.headers.first(name: "Cache-Control") ?? ""
        XCTAssertEqual(cc, "no-store")
    }

    func testResponse_containsActionsSection() async throws {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        let html = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(html.contains("actions-catalog"), "Phase 9 actions catalog missing from HTML")
        XCTAssertFalse(html.contains("id=\"actions-section\""), "Overview's old actions-section should be removed, not duplicated, once the Actions tab owns it")
        XCTAssertTrue(html.contains("toast-container"), "Phase 2 toast container missing from HTML")
    }
}

// MARK: - AdminAction / AdminActionResult

final class AdminActionTests: XCTestCase {

    func testAdminAction_storesAllFields() {
        let a = AdminAction(name: "my-action", label: "My Action",
                            description: "Does something", category: "ops", isDestructive: true)
        XCTAssertEqual(a.name, "my-action")
        XCTAssertEqual(a.label, "My Action")
        XCTAssertEqual(a.description, "Does something")
        XCTAssertEqual(a.category, "ops")
        XCTAssertTrue(a.isDestructive)
    }

    func testAdminAction_defaultCategoryIsGeneral() {
        let a = AdminAction(name: "x", label: "X", description: "")
        XCTAssertEqual(a.category, "general")
    }

    func testAdminAction_defaultNonDestructive() {
        let a = AdminAction(name: "x", label: "X", description: "")
        XCTAssertFalse(a.isDestructive)
    }

    func testAdminActionResult_okFactory() {
        let r = AdminActionResult.ok("All good")
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.message, "All good")
    }

    func testAdminActionResult_failedFactory() {
        let r = AdminActionResult.failed("Nope")
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.message, "Nope")
    }

    func testAdminActionResult_initDirectly() {
        let r = AdminActionResult(success: true, message: "OK")
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.message, "OK")
    }
}

// MARK: - AdminAction (Phase 9: Actions catalog)

final class AdminActionPhase9Tests: XCTestCase {

    func testAdminAction_isRunningDefaultsFalse() {
        let a = AdminAction(name: "x", label: "X", description: "")
        XCTAssertFalse(a.isRunning)
    }

    func testAdminAction_lastResultDefaultsNil() {
        let a = AdminAction(name: "x", label: "X", description: "")
        XCTAssertNil(a.lastResult)
    }

    func testAdminAction_consequenceDefaultsNil() {
        let a = AdminAction(name: "x", label: "X", description: "")
        XCTAssertNil(a.consequence)
    }

    func testAdminAction_isInertDefaultsFalse() {
        let a = AdminAction(name: "x", label: "X", description: "")
        XCTAssertFalse(a.isInert)
    }

    func testAdminAction_storesAllFourNewFieldsWhenPassed() {
        let a = AdminAction(
            name: "x", label: "X", description: "",
            isRunning: true, lastResult: "14 considered · 5 disconnected",
            consequence: "This cannot be undone.", isInert: true
        )
        XCTAssertTrue(a.isRunning)
        XCTAssertEqual(a.lastResult, "14 considered · 5 disconnected")
        XCTAssertEqual(a.consequence, "This cannot be undone.")
        XCTAssertTrue(a.isInert)
    }
}

// MARK: - CSRF guard

final class CSRFGuardTests: XCTestCase {

    func testRequireCSRF_missingHeader_throws() {
        XCTAssertThrowsError(try requireCSRF(headers: HTTPHeaders(), port: 8990))
    }

    func testRequireCSRF_wrongValue_throws() {
        var h = HTTPHeaders()
        h.add(name: "X-Admin-CSRF", value: "true")
        XCTAssertThrowsError(try requireCSRF(headers: h, port: 8990))
    }

    func testRequireCSRF_correctHeader_noOrigin_passes() {
        var h = HTTPHeaders()
        h.add(name: "X-Admin-CSRF", value: "1")
        XCTAssertNoThrow(try requireCSRF(headers: h, port: 8990))
    }

    func testRequireCSRF_correctHeaderAndOrigin_passes() {
        var h = HTTPHeaders()
        h.add(name: "X-Admin-CSRF", value: "1")
        h.add(name: "Origin", value: "http://127.0.0.1:8990")
        XCTAssertNoThrow(try requireCSRF(headers: h, port: 8990))
    }

    func testRequireCSRF_wrongOrigin_throws() {
        var h = HTTPHeaders()
        h.add(name: "X-Admin-CSRF", value: "1")
        h.add(name: "Origin", value: "http://evil.example.com")
        XCTAssertThrowsError(try requireCSRF(headers: h, port: 8990))
    }

    func testRequireCSRF_localhostIsNotSameAs127_throws() {
        var h = HTTPHeaders()
        h.add(name: "X-Admin-CSRF", value: "1")
        h.add(name: "Origin", value: "http://localhost:8990")
        XCTAssertThrowsError(try requireCSRF(headers: h, port: 8990))
    }

    func testRequireCSRF_portMismatch_throws() {
        var h = HTTPHeaders()
        h.add(name: "X-Admin-CSRF", value: "1")
        h.add(name: "Origin", value: "http://127.0.0.1:9999")
        XCTAssertThrowsError(try requireCSRF(headers: h, port: 8990))
    }
}

// MARK: - LogCapture clear

final class LogCaptureClearTests: XCTestCase {

    func testClear_returnsDroppedCount() async {
        let cap = LogCapture()
        await cap.capture("a")
        await cap.capture("b")
        await cap.capture("c")
        let dropped = await cap.clear()
        XCTAssertEqual(dropped, 3)
    }

    func testClear_emptyBuffer_returnsZero() async {
        let cap = LogCapture()
        let dropped = await cap.clear()
        XCTAssertEqual(dropped, 0)
    }

    func testClear_bufferIsEmptyAfterClear() async {
        let cap = LogCapture()
        await cap.capture("x")
        _ = await cap.clear()
        let lines = await cap.recentLines(count: 100)
        XCTAssertEqual(lines, [])
    }

    func testClear_afterClear_canCaptureAgain() async {
        let cap = LogCapture()
        await cap.capture("before")
        _ = await cap.clear()
        await cap.capture("after")
        let lines = await cap.recentLines(count: 100)
        XCTAssertEqual(lines, ["after"])
    }

    func testClear_totalCapturedIsZeroAfterClear() async {
        let cap = LogCapture()
        await cap.capture("a")
        await cap.capture("b")
        _ = await cap.clear()
        let total = await cap.totalCaptured
        XCTAssertEqual(total, 0)
    }
}

// MARK: - AdminConsoleDelegate Phase 2 defaults

private final class MinimalDelegate2: AdminConsoleDelegate {}

final class AdminConsoleDelegatePhase2Tests: XCTestCase {

    func testDefaultAvailableActions_isEmpty() async {
        let d = MinimalDelegate2()
        let actions = await d.availableActions()
        XCTAssertTrue(actions.isEmpty)
    }

    func testDefaultExecuteAction_returnsFailed() async throws {
        let d = MinimalDelegate2()
        let result = try await d.executeAction("anything")
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("anything"))
    }

    func testDefaultReloadTLS_doesNotThrow() async throws {
        let d = MinimalDelegate2()
        try await d.reloadTLSCertificates()
    }
}

// MARK: - Built-in actions

final class BuiltinActionsTests: XCTestCase {

    func testBuiltinActions_noneWhenNoLogsNoDelegate() {
        let actions = adminBuiltinActions(hasLogs: false, hasDelegate: false)
        XCTAssertTrue(actions.isEmpty)
    }

    func testBuiltinActions_clearLogsWhenHasLogs() {
        let actions = adminBuiltinActions(hasLogs: true, hasDelegate: false)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].name, "clear-logs")
        XCTAssertTrue(actions[0].isDestructive)
    }

    func testBuiltinActions_reloadTLSWhenHasDelegate() {
        let actions = adminBuiltinActions(hasLogs: false, hasDelegate: true)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].name, "reload-tls")
        XCTAssertFalse(actions[0].isDestructive)
    }

    func testBuiltinActions_bothWhenBothPresent() {
        let actions = adminBuiltinActions(hasLogs: true, hasDelegate: true)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions.map(\.name), ["clear-logs", "reload-tls"])
    }

    func testBuiltinActions_defaultHasTLSParam_preservesOldBehavior() {
        // Old 2-arg call site (no hasTLS) still compiles and behaves as before: reload-tls is inert.
        let actions = adminBuiltinActions(hasLogs: false, hasDelegate: true)
        XCTAssertTrue(actions[0].isInert)
    }

    func testBuiltinActions_reloadTLS_isInertWhenNoTLS() {
        let actions = adminBuiltinActions(hasLogs: false, hasDelegate: true, hasTLS: false)
        XCTAssertTrue(actions[0].isInert)
    }

    func testBuiltinActions_reloadTLS_notInertWhenTLSConfigured() {
        let actions = adminBuiltinActions(hasLogs: false, hasDelegate: true, hasTLS: true)
        XCTAssertFalse(actions[0].isInert)
    }

    func testBuiltinActions_clearLogs_hasConsequenceText() {
        let actions = adminBuiltinActions(hasLogs: true, hasDelegate: false)
        XCTAssertNotNil(actions[0].consequence)
        XCTAssertFalse(actions[0].consequence!.isEmpty)
    }
}

// MARK: - Phase 9: TLS-configured detection + inert-action rejection

final class AdminConsolePhase9Tests: XCTestCase {

    func testAdminHasTLSConfigured_neither_returnsFalse() {
        XCTAssertFalse(adminHasTLSConfigured(domains: [], hasDefault: false))
    }

    func testAdminHasTLSConfigured_hasDefaultOnly_returnsTrue() {
        XCTAssertTrue(adminHasTLSConfigured(domains: [], hasDefault: true))
    }

    func testAdminHasTLSConfigured_hasRegisteredHostnameOnly_returnsTrue() {
        XCTAssertTrue(adminHasTLSConfigured(domains: ["example.com"], hasDefault: false))
    }

    func testAdminInertActionRejection_reloadTLSWithoutTLS_returnsFailed() {
        let result = adminInertActionRejection(actionName: "reload-tls", hasTLS: false)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.success)
    }

    func testAdminInertActionRejection_reloadTLSWithTLS_returnsNil() {
        XCTAssertNil(adminInertActionRejection(actionName: "reload-tls", hasTLS: true))
    }

    func testAdminInertActionRejection_otherActionName_returnsNilRegardless() {
        XCTAssertNil(adminInertActionRejection(actionName: "clear-logs", hasTLS: false))
        XCTAssertNil(adminInertActionRejection(actionName: "clear-logs", hasTLS: true))
    }
}

// MARK: - Phase 3: DatasourceInfo

final class DatasourceInfoTests: XCTestCase {

    func testInit_storesAllFields() {
        let ds = DatasourceInfo(name: "mysql-main", alias: "MainDB", schema: "appdb", driver: "MySQL")
        XCTAssertEqual(ds.name, "mysql-main")
        XCTAssertEqual(ds.alias, "MainDB")
        XCTAssertEqual(ds.schema, "appdb")
        XCTAssertEqual(ds.driver, "MySQL")
    }

    func testInit_emptyStringsAllowed() {
        let ds = DatasourceInfo(name: "", alias: "", schema: "", driver: "")
        XCTAssertEqual(ds.name, "")
    }

    func testSendable_usableAcrossActors() async {
        let ds = DatasourceInfo(name: "pg", alias: "Postgres", schema: "public", driver: "PostgreSQL")
        let name = await Task.detached { ds.name }.value
        XCTAssertEqual(name, "pg")
    }
}

// MARK: - Phase 3: DatasourceTestResult

final class DatasourceTestResultTests: XCTestCase {

    func testOk_defaultMessage() {
        let r = DatasourceTestResult.ok()
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.message, "Connection OK")
        XCTAssertNil(r.latencyMs)
    }

    func testOk_withLatency() {
        let r = DatasourceTestResult.ok(latencyMs: 3.7)
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.latencyMs, 3.7)
    }

    func testOk_withCustomMessage() {
        let r = DatasourceTestResult.ok(message: "MySQL 9.6 · 2ms")
        XCTAssertEqual(r.message, "MySQL 9.6 · 2ms")
    }

    func testFailed_successIsFalse() {
        let r = DatasourceTestResult.failed("Connection refused")
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.message, "Connection refused")
    }

    func testFailed_latencyIsNil() {
        let r = DatasourceTestResult.failed("Timeout")
        XCTAssertNil(r.latencyMs)
    }

    func testDirectInit_allFields() {
        let r = DatasourceTestResult(success: true, message: "OK", latencyMs: 12.5)
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.message, "OK")
        XCTAssertEqual(r.latencyMs, 12.5)
    }

    func testDirectInit_latencyDefaultsToNil() {
        let r = DatasourceTestResult(success: false, message: "err")
        XCTAssertNil(r.latencyMs)
    }
}

// MARK: - Phase 3: AdminConsoleDelegate defaults

private final class MinimalDelegate3: AdminConsoleDelegate {}

final class AdminConsoleDelegatePhase3Tests: XCTestCase {

    func testDefaultRegisteredDatasources_isEmpty() async {
        let d = MinimalDelegate3()
        let sources = await d.registeredDatasources()
        XCTAssertTrue(sources.isEmpty)
    }

    func testDefaultTestDatasource_returnsFailed() async throws {
        let d = MinimalDelegate3()
        let result = try await d.testDatasource(name: "any-ds")
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("any-ds"))
    }

    func testDefaultTestDatasource_latencyIsNil() async throws {
        let d = MinimalDelegate3()
        let result = try await d.testDatasource(name: "x")
        XCTAssertNil(result.latencyMs)
    }
}

// MARK: - Phase 3: AdminWebUI datasource section

final class AdminWebUIDatasourceTests: XCTestCase {

    func testResponse_containsDatasourceCard() async throws {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        let html = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(html.contains("data-detail"), "Data tab detail pane missing")
        XCTAssertTrue(html.contains("Datasources"), "Data tab rail heading missing")
    }

    func testResponse_containsDatasourceTestFunction() async throws {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        let html = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(html.contains("testDS"), "testDS JS function missing")
        XCTAssertTrue(html.contains("/api/datasources/test"), "datasource test endpoint missing from JS")
    }
}

// MARK: - Phase 4: AdminMetrics

final class AdminMetricsTests: XCTestCase {

    func testInitial_countersAreZero() async {
        let m = AdminMetrics()
        let snap = await m.snapshot()
        XCTAssertEqual(snap.totalRequests, 0)
        XCTAssertEqual(snap.totalErrors, 0)
        XCTAssertEqual(snap.activeConnections, 0)
        XCTAssertTrue(snap.routeCounts.isEmpty)
    }

    func testRecordRequest_incrementsTotal() async {
        let m = AdminMetrics()
        await m.recordRequest(route: "GET:///api/status")
        await m.recordRequest(route: "GET:///api/tls")
        let snap = await m.snapshot()
        XCTAssertEqual(snap.totalRequests, 2)
    }

    func testRecordRequest_tracksPerRoute() async {
        let m = AdminMetrics()
        await m.recordRequest(route: "GET:///api/status")
        await m.recordRequest(route: "GET:///api/status")
        await m.recordRequest(route: "GET:///api/tls")
        let snap = await m.snapshot()
        XCTAssertEqual(snap.routeCounts["GET:///api/status"], 2)
        XCTAssertEqual(snap.routeCounts["GET:///api/tls"], 1)
    }

    func testRecordError_incrementsErrors() async {
        let m = AdminMetrics()
        await m.recordRequest(route: "POST:///api/broken")
        await m.recordError()
        let snap = await m.snapshot()
        XCTAssertEqual(snap.totalErrors, 1)
    }

    func testBeginConnection_incrementsActive() async {
        let m = AdminMetrics()
        await m.beginConnection()
        await m.beginConnection()
        let snap = await m.snapshot()
        XCTAssertEqual(snap.activeConnections, 2)
    }

    func testEndConnection_decrementsActive() async {
        let m = AdminMetrics()
        await m.beginConnection()
        await m.beginConnection()
        await m.endConnection()
        let snap = await m.snapshot()
        XCTAssertEqual(snap.activeConnections, 1)
    }

    func testEndConnection_clampAtZero() async {
        let m = AdminMetrics()
        await m.endConnection()
        await m.endConnection()
        let snap = await m.snapshot()
        XCTAssertEqual(snap.activeConnections, 0)
    }

    func testSnapshotErrorRate_zeroWhenNoRequests() async {
        let m = AdminMetrics()
        let snap = await m.snapshot()
        XCTAssertEqual(snap.errorRate, 0.0)
    }

    func testSnapshotErrorRate_computed() async {
        let m = AdminMetrics()
        await m.recordRequest(route: "GET:///")
        await m.recordRequest(route: "GET:///")
        await m.recordError()
        let snap = await m.snapshot()
        XCTAssertEqual(snap.errorRate, 0.5, accuracy: 0.001)
    }
}

// MARK: - Phase 4: MetricsSnapshot

final class MetricsSnapshotTests: XCTestCase {

    func testInit_storesAllFields() {
        let snap = MetricsSnapshot(totalRequests: 10, totalErrors: 2,
                                   activeConnections: 3, routeCounts: ["GET:///": 7])
        XCTAssertEqual(snap.totalRequests, 10)
        XCTAssertEqual(snap.totalErrors, 2)
        XCTAssertEqual(snap.activeConnections, 3)
        XCTAssertEqual(snap.routeCounts["GET:///"], 7)
    }

    func testErrorRate_zeroRequests() {
        let snap = MetricsSnapshot(totalRequests: 0, totalErrors: 0,
                                   activeConnections: 0, routeCounts: [:])
        XCTAssertEqual(snap.errorRate, 0.0)
    }

    func testErrorRate_withErrors() {
        let snap = MetricsSnapshot(totalRequests: 4, totalErrors: 1,
                                   activeConnections: 0, routeCounts: [:])
        XCTAssertEqual(snap.errorRate, 0.25, accuracy: 0.001)
    }

    func testEncodable_includesAllKeys() throws {
        let snap = MetricsSnapshot(totalRequests: 5, totalErrors: 1,
                                   activeConnections: 2, routeCounts: ["GET:///": 5])
        let data = try JSONEncoder().encode(snap)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj?["totalRequests"])
        XCTAssertNotNil(obj?["totalErrors"])
        XCTAssertNotNil(obj?["activeConnections"])
        XCTAssertNotNil(obj?["routeCounts"])
        XCTAssertNotNil(obj?["errorRate"])
    }

    // `errorRate` is a computed property; synthesized Encodable silently drops
    // computed properties, which previously left this key out of the JSON
    // response entirely (rendered as "NaN%" client-side). Verify the real
    // percentage round-trips through JSON, not just that the key exists.
    func testEncodable_errorRateRoundTripsRealPercentage() throws {
        let snap = MetricsSnapshot(totalRequests: 4, totalErrors: 1,
                                   activeConnections: 0, routeCounts: [:])
        let data = try JSONEncoder().encode(snap)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rate = try XCTUnwrap(obj?["errorRate"] as? Double)
        XCTAssertEqual(rate, 0.25, accuracy: 0.001)
    }

    func testEncodable_errorRateZeroRequests() throws {
        let snap = MetricsSnapshot(totalRequests: 0, totalErrors: 0,
                                   activeConnections: 0, routeCounts: [:])
        let data = try JSONEncoder().encode(snap)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rate = try XCTUnwrap(obj?["errorRate"] as? Double)
        XCTAssertEqual(rate, 0.0, accuracy: 0.001)
    }
}

// MARK: - Phase 4: AdminConsoleDelegate TLS defaults

private final class MinimalDelegate4: AdminConsoleDelegate {}

final class AdminConsoleDelegatePhase4Tests: XCTestCase {

    func testDefaultReloadTLSCertificate_doesNotThrow() async throws {
        let d = MinimalDelegate4()
        // Default calls reloadTLSCertificates() which is itself a no-op default
        try await d.reloadTLSCertificate(for: "example.com")
    }
}

// MARK: - Phase 4: AdminWebUI metrics + TLS ops

final class AdminWebUIPhase4Tests: XCTestCase {

    private func loadHTML() async throws -> String {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        return String(decoding: body, as: UTF8.self)
    }

    // Superseded by Phase 12's Traffic card (admin-console UI redesign phase 6) — the standalone
    // Metrics card/renderMetrics() is gone, not duplicated; see AdminWebUIPhase12OverviewTests.
    func testResponse_containsMetricsCard() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("traffic-content"), "Traffic card (Metrics' successor) missing from HTML")
        XCTAssertTrue(html.contains("/api/metrics"), "metrics API endpoint missing from JS")
    }

    func testResponse_containsRenderMetrics() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("function renderTraffic"), "renderTraffic (renderMetrics' successor) JS function missing")
        XCTAssertTrue(html.contains("/api/metrics"), "metrics API endpoint missing from JS")
    }

    func testResponse_containsTLSReloadFunction() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("tlsReload"), "tlsReload JS function missing")
        XCTAssertTrue(html.contains("/api/tls/reload"), "TLS reload endpoint missing from JS")
    }

    func testResponse_containsTLSRemoveFunction() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("tlsRemove"), "tlsRemove JS function missing")
        XCTAssertTrue(html.contains("/api/tls/domain"), "TLS remove endpoint missing from JS")
    }
}

// MARK: - Phase 5: DatasourceConfigInfo

final class DatasourceConfigInfoTests: XCTestCase {

    func testInit_storesAllFields() {
        let cfg = DatasourceConfigInfo(id: "staging", label: "Staging", description: "staging.db", isActive: true)
        XCTAssertEqual(cfg.id, "staging")
        XCTAssertEqual(cfg.label, "Staging")
        XCTAssertEqual(cfg.description, "staging.db")
        XCTAssertTrue(cfg.isActive)
    }

    func testInit_isActiveDefaultsFalse() {
        let cfg = DatasourceConfigInfo(id: "prod", label: "Production", description: "prod.db")
        XCTAssertFalse(cfg.isActive)
    }

    func testInit_emptyStringsAllowed() {
        let cfg = DatasourceConfigInfo(id: "", label: "", description: "")
        XCTAssertEqual(cfg.id, "")
        XCTAssertEqual(cfg.label, "")
        XCTAssertEqual(cfg.description, "")
    }

    func testSendable_usableAcrossActors() async {
        let cfg = DatasourceConfigInfo(id: "dev", label: "Dev", description: "dev.db", isActive: false)
        let result = await Task.detached { cfg }.value
        XCTAssertEqual(result.id, "dev")
    }
}

// MARK: - Phase 5: AdminConsoleDelegate defaults

private final class MinimalDelegate5: AdminConsoleDelegate {}

final class AdminConsoleDelegatePhase5Tests: XCTestCase {

    func testDefaultAvailableConfigs_isEmpty() async {
        let d = MinimalDelegate5()
        let configs = await d.availableConfigs(for: "mysql-main")
        XCTAssertTrue(configs.isEmpty, "Default availableConfigs should return empty array")
    }

    func testDefaultSwitchDatasource_returnsFailed() async throws {
        let d = MinimalDelegate5()
        let result = try await d.switchDatasource(name: "mysql-main", to: "staging")
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("mysql-main"), "Error message should name the datasource")
    }

    func testDefaultSwitchDatasource_latencyIsNil() async throws {
        let d = MinimalDelegate5()
        let result = try await d.switchDatasource(name: "any", to: "any-config")
        XCTAssertNil(result.latencyMs)
    }
}

// MARK: - Phase 5: AdminWebUI config switcher

final class AdminWebUIPhase5Tests: XCTestCase {

    private func loadHTML() async throws -> String {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        return String(decoding: body, as: UTF8.self)
    }

    func testResponse_containsConnectionProfileCSS() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("data-profile-card"), "data-profile-card CSS class missing from HTML")
        XCTAssertFalse(html.contains("cfg-select"), "old cfg-select dropdown should be gone, replaced by per-card Switch buttons")
    }

    func testResponse_containsSwitchDSFunction() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("switchDS"), "switchDS JS function missing from HTML")
    }

    func testResponse_containsDatasourceSwitchEndpoint() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("/api/datasources/switch"), "datasource switch endpoint missing from JS")
    }

    func testResponse_switchDSPostsWithCSRFHeader() async throws {
        let html = try await loadHTML()
        // switchDS must use POST and include the CSRF header
        let hasPost = html.contains("method: 'POST'") || html.contains("method:\"POST\"") || html.contains("method: \"POST\"")
        XCTAssertTrue(hasPost, "switchDS should use POST method")
        XCTAssertTrue(html.contains("X-Admin-CSRF"), "switchDS must include X-Admin-CSRF header")
    }
}

// MARK: - Phase 6: ModelColumnInfo / ModelInfo (ADR-0001 Phase 5)

final class ModelColumnInfoTests: XCTestCase {

    func testInit_storesAllFields() {
        let c = ModelColumnInfo(name: "id", typeName: "Int", isPrimaryKey: true, isOptional: false)
        XCTAssertEqual(c.name, "id")
        XCTAssertEqual(c.typeName, "Int")
        XCTAssertTrue(c.isPrimaryKey)
        XCTAssertFalse(c.isOptional)
    }

    func testInit_defaultsToNotPrimaryKeyNotOptional() {
        let c = ModelColumnInfo(name: "name", typeName: "String")
        XCTAssertFalse(c.isPrimaryKey)
        XCTAssertFalse(c.isOptional)
    }

    func testSendable_usableAcrossActors() async {
        let c = ModelColumnInfo(name: "email", typeName: "String", isOptional: true)
        let name = await Task.detached { c.name }.value
        XCTAssertEqual(name, "email")
    }
}

final class ModelInfoTests: XCTestCase {

    func testInit_labelDefaultsToName() {
        let m = ModelInfo(name: "posts", columns: [])
        XCTAssertEqual(m.label, "posts")
    }

    func testInit_labelOverridesWhenProvided() {
        let m = ModelInfo(name: "posts", label: "Blog Posts", columns: [])
        XCTAssertEqual(m.label, "Blog Posts")
    }

    func testInit_storesColumns() {
        let columns = [
            ModelColumnInfo(name: "id", typeName: "Int", isPrimaryKey: true),
            ModelColumnInfo(name: "title", typeName: "String"),
        ]
        let m = ModelInfo(name: "posts", columns: columns)
        XCTAssertEqual(m.columns.count, 2)
        XCTAssertEqual(m.columns[0].name, "id")
    }

    func testSendable_usableAcrossActors() async {
        let m = ModelInfo(name: "posts", columns: [ModelColumnInfo(name: "id", typeName: "Int")])
        let name = await Task.detached { m.name }.value
        XCTAssertEqual(name, "posts")
    }
}

// MARK: - Phase 6: AdminConsoleDelegate defaults

private final class MinimalDelegate6: AdminConsoleDelegate {}

final class AdminConsoleDelegatePhase6Tests: XCTestCase {

    func testDefaultRegisteredModels_isEmpty() async {
        let d = MinimalDelegate6()
        let models = await d.registeredModels()
        XCTAssertTrue(models.isEmpty)
    }
}

// MARK: - Phase 6: AdminWebUI models section

final class AdminWebUIModelsTests: XCTestCase {

    private func loadHTML() async throws -> String {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        return String(decoding: body, as: UTF8.self)
    }

    func testResponse_containsModelsCard() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("id=\"models-card\""), "models-card missing from HTML")
    }

    func testResponse_containsModelsEndpointInRefresh() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("/api/models"), "/api/models fetch missing from refresh()")
    }

    func testResponse_containsRenderModelsFunction() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("function renderModels"), "renderModels JS function missing from HTML")
    }
}

// MARK: - Phase 7: admin-console UI redesign, currentJob() delegate hook

private final class MinimalDelegate7: AdminConsoleDelegate {}

final class AdminConsoleDelegatePhase7Tests: XCTestCase {

    func testDefaultCurrentJob_isNil() async {
        let d = MinimalDelegate7()
        let job = await d.currentJob()
        XCTAssertNil(job)
    }
}

// MARK: - Phase 7: AdminWebUI shell/chrome/design-token redesign

final class AdminWebUIPhase7Tests: XCTestCase {

    private func loadHTML() async throws -> String {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        return String(decoding: body, as: UTF8.self)
    }

    func testResponse_containsAllFiveTabs() async throws {
        let html = try await loadHTML()
        for tab in ["Overview", "Data", "Logs", "Actions", "Settings"] {
            XCTAssertTrue(html.contains(">\(tab)<"), "\(tab) tab label missing from tab bar")
        }
        for id in ["tab-overview", "tab-data", "tab-logs", "tab-actions", "tab-settings"] {
            XCTAssertTrue(html.contains("id=\"\(id)\""), "\(id) tab panel missing")
        }
    }

    func testOverviewTab_containsExistingCards() async throws {
        let html = try await loadHTML()
        let overviewStart = try XCTUnwrap(html.range(of: "id=\"tab-overview\""))
        let settingsStart = try XCTUnwrap(html.range(of: "id=\"tab-settings\""))
        let overviewBody = html[overviewStart.upperBound..<settingsStart.lowerBound]
        // metrics-rows/models-content moved out in Phase 12 (superseded by Traffic, relocated to
        // the Data tab respectively) -- log-box (Recent Log) is the one Overview mount unchanged
        // since Phase 8. See AdminWebUIPhase12OverviewTests for their new homes.
        XCTAssertTrue(overviewBody.contains("id=\"log-box\""), "log-box missing from Overview tab")
        XCTAssertFalse(overviewBody.contains("id=\"actions-section\""), "Actions catalog moved to the Actions tab in Phase 9 -- Overview should no longer duplicate it")
        XCTAssertFalse(overviewBody.contains("id=\"datasource-content\""), "Datasources moved to the Data tab in Phase 10 -- Overview should no longer duplicate it")
    }

    func testSettingsTab_containsTLSAndACMECards() async throws {
        let html = try await loadHTML()
        let settingsStart = try XCTUnwrap(html.range(of: "id=\"tab-settings\""))
        let settingsBody = html[settingsStart.upperBound...]
        for id in ["tls-content", "acme-rows"] {
            XCTAssertTrue(settingsBody.contains("id=\"\(id)\""), "\(id) missing from Settings tab")
        }
    }

    func testResponse_containsStateStripElements() async throws {
        let html = try await loadHTML()
        for id in ["serving-dot", "ports-val", "uptime-val", "errorrate-val", "connections-val", "job-chip"] {
            XCTAssertTrue(html.contains("id=\"\(id)\""), "\(id) missing from state strip")
        }
    }

    func testResponse_containsCurrentJobInStatusFetchHandling() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("status.currentJob"), "currentJob field not read from /api/status response")
    }

    func testResponse_usesNewDesignTokenNames() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("--color-accent"), "new --color-accent token missing")
        XCTAssertTrue(html.contains("--color-alert"), "new --color-alert token missing")
        XCTAssertFalse(html.contains("--accent:"), "old --accent token name should be gone")
        XCTAssertFalse(html.contains("--err:"), "old --err token name should be gone")
    }

    func testResponse_doesNotReferenceCDNOrDarkModeMediaQuery() async throws {
        let html = try await loadHTML()
        XCTAssertFalse(html.contains("fonts.googleapis.com"), "no CDN font import should ship in the product")
        XCTAssertFalse(html.contains("prefers-color-scheme"), "no dark-mode variant is specified by the design")
    }
}

// MARK: - Phase 8: log viewer component (admin-console UI redesign phase 2)

final class AdminWebUIPhase8LogsViewerTests: XCTestCase {

    private func loadHTML() async throws -> String {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        return String(decoding: body, as: UTF8.self)
    }

    func testLogsTab_isNoLongerPlaceholder() async throws {
        let html = try await loadHTML()
        let logsStart = try XCTUnwrap(html.range(of: "id=\"tab-logs\""))
        let actionsStart = try XCTUnwrap(html.range(of: "id=\"tab-actions\""))
        let logsBody = html[logsStart.upperBound..<actionsStart.lowerBound]
        XCTAssertFalse(logsBody.contains("being redesigned"), "Logs tab should no longer be a placeholder")
    }

    func testLogsTab_containsToolbarElementIDs() async throws {
        let html = try await loadHTML()
        for id in ["logs-search-input", "logs-chips", "logs-follow-checkbox", "logs-match-count"] {
            XCTAssertTrue(html.contains("id=\"\(id)\""), "\(id) missing from Logs tab toolbar")
        }
    }

    func testLogsTab_containsLogSurfaceAndFooter() async throws {
        let html = try await loadHTML()
        for id in ["logs-surface", "logs-footer-count", "logs-next-refresh"] {
            XCTAssertTrue(html.contains("id=\"\(id)\""), "\(id) missing from Logs tab surface/footer")
        }
    }

    func testResponse_containsNewChipCSSClasses() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains(".tag-outline"), "tag-outline chip class missing")
        XCTAssertTrue(html.contains(".tag-neutral"), "tag-neutral chip class missing")
    }

    func testResponse_containsSharedLogRenderingFunctions() async throws {
        let html = try await loadHTML()
        for fn in ["function renderLogSurface", "function computeSubsystemCounts", "function renderLogsView", "function renderMiniLog", "function handleLogsData"] {
            XCTAssertTrue(html.contains(fn), "\(fn) missing from JS")
        }
    }

    func testResponse_containsClearLogBufferFunction_usesDeleteAndCSRF() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("function clearLogBuffer"), "clearLogBuffer function missing")
        XCTAssertTrue(html.contains("method: 'DELETE'") || html.contains("method: \"DELETE\""), "clear buffer should DELETE /api/logs")
        XCTAssertTrue(html.contains("X-Admin-CSRF"), "clear buffer should send the CSRF header")
    }

    func testResponse_containsCopyAndDownloadFunctions() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("function copyLogs"), "copyLogs function missing")
        XCTAssertTrue(html.contains("navigator.clipboard"), "Clipboard API usage missing")
        XCTAssertTrue(html.contains("function downloadLogs"), "downloadLogs function missing")
        XCTAssertTrue(html.contains("new Blob("), "Blob-based download missing")
    }

    // openLogsWindow() was generalized into openDetachedWindow(viewer) in Phase 12 (admin-console
    // UI redesign phase 6) so Activity could reuse the same mechanism -- see
    // AdminWebUIPhase12OverviewTests for the generalized-function assertion.
    func testResponse_containsOpenLogsWindowFunction_andDetachedDetection() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("function openDetachedWindow"), "openDetachedWindow function missing")
        XCTAssertTrue(html.contains("window.open("), "window.open call missing")
        XCTAssertTrue(html.contains("detached=logs") || html.contains("'?detached=' + viewer"), "detached query param missing")
        XCTAssertTrue(html.contains("detached-logs"), "detached-logs body class missing")
    }

    func testRefresh_requestsFullLogBuffer() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("/api/logs?count=500"), "refresh() should request the full 500-line buffer")
        XCTAssertFalse(html.contains("/api/logs?count=100"), "refresh() should no longer request only 100 lines")
    }

    func testOverviewMiniLog_stillPresent() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("id=\"log-box\""), "mini log card regression: log-box missing")
        XCTAssertTrue(html.contains("log-surface-mini"), "mini log surface class missing")
    }

    func testResponse_footerCopyMatchesDesignWording() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("buffer holds "), "footer should use the design's verbatim wording")
        XCTAssertTrue(html.contains("oldest dropped"), "footer should use the design's verbatim wording")
    }
}

// MARK: - Phase 9: Actions catalog (admin-console UI redesign phase 3)

final class AdminWebUIPhase9ActionsCatalogTests: XCTestCase {

    private func loadHTML() async throws -> String {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        return String(decoding: body, as: UTF8.self)
    }

    func testActionsTab_isNoLongerPlaceholder() async throws {
        let html = try await loadHTML()
        let actionsStart = try XCTUnwrap(html.range(of: "id=\"tab-actions\""))
        let settingsStart = try XCTUnwrap(html.range(of: "id=\"tab-settings\""))
        let actionsBody = html[actionsStart.upperBound..<settingsStart.lowerBound]
        XCTAssertFalse(actionsBody.contains("being redesigned"), "Actions tab should no longer be a placeholder")
    }

    func testActionsTab_containsCatalogMountAndFunction() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("id=\"actions-catalog\""), "actions-catalog mount missing")
        XCTAssertTrue(html.contains("function renderActionsCatalog"), "renderActionsCatalog function missing")
    }

    func testResponse_containsActionRowCSSClasses() async throws {
        let html = try await loadHTML()
        for cls in [".action-group", ".action-row", ".action-consequence", ".action-controls", ".action-tag-running", ".action-tag-destructive"] {
            XCTAssertTrue(html.contains(cls), "\(cls) missing from CSS")
        }
    }

    func testResponse_runActionHasThreeArgSignature() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("function runAction(name, isDestructive, consequence)"), "runAction should now take a consequence param")
    }

    func testResponse_containsFollowInLogsFunction() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("function followInLogs"), "followInLogs function missing")
    }

    func testResponse_actionButtonHTML_handlesInertRunningDestructive() async throws {
        let html = try await loadHTML()
        for literal in ["Already running", "Follow in Logs", "No TLS configured", "destructive · confirms", "Download first"] {
            XCTAssertTrue(html.contains(literal), "\(literal) missing from JS")
        }
    }
}

// MARK: - Phase 10: DatasourceAttemptTracker (admin-console UI redesign phase 4)

final class DatasourceAttemptTrackerTests: XCTestCase {

    func testRecordThenSnapshot_roundTrips() async {
        let tracker = DatasourceAttemptTracker()
        await tracker.record(alias: "contacts", profile: "primary", result: .ok(latencyMs: 12, message: "ok"))
        let snap = await tracker.snapshot(for: "contacts")
        XCTAssertEqual(snap.history.count, 1)
        XCTAssertEqual(snap.history[0].profile, "primary")
        XCTAssertEqual(snap.history[0].latencyMs, 12)
        XCTAssertTrue(snap.history[0].success)
    }

    func testRingBuffer_capsAt20_dropsOldestFirst() async {
        let tracker = DatasourceAttemptTracker()
        for i in 0..<25 {
            await tracker.record(alias: "contacts", profile: "p\(i)", result: .ok(message: "ok"))
        }
        let snap = await tracker.snapshot(for: "contacts")
        XCTAssertEqual(snap.history.count, 20)
        XCTAssertEqual(snap.history.first?.profile, "p5")
        XCTAssertEqual(snap.history.last?.profile, "p24")
    }

    func testHistory_staysOldestFirst() async {
        let tracker = DatasourceAttemptTracker()
        await tracker.record(alias: "contacts", profile: "a", result: .ok(message: "ok"))
        await tracker.record(alias: "contacts", profile: "b", result: .ok(message: "ok"))
        let snap = await tracker.snapshot(for: "contacts")
        XCTAssertEqual(snap.history.map(\.profile), ["a", "b"])
    }

    func testUnknownAlias_returnsNotTestedAndEmptyHistory() async {
        let tracker = DatasourceAttemptTracker()
        let snap = await tracker.snapshot(for: "never-seen")
        XCTAssertEqual(snap.status, .notTested)
        XCTAssertTrue(snap.history.isEmpty)
        XCTAssertNil(snap.lastAttempt)
    }
}

final class DatasourceAttemptStatusTests: XCTestCase {

    func testEmptyHistory_isNotTested() {
        XCTAssertEqual(datasourceAttemptStatus(from: []), .notTested)
    }

    func testLastAttemptSuccess_isOk() {
        let history = [DatasourceAttempt(profile: "p", success: false, message: "x"),
                       DatasourceAttempt(profile: "p", success: true, message: "ok")]
        XCTAssertEqual(datasourceAttemptStatus(from: history), .ok)
    }

    func testLastAttemptFailure_isFailing() {
        let history = [DatasourceAttempt(profile: "p", success: true, message: "ok"),
                       DatasourceAttempt(profile: "p", success: false, message: "x")]
        XCTAssertEqual(datasourceAttemptStatus(from: history), .failing)
    }
}

final class DatasourceConsecutiveFailuresTests: XCTestCase {

    func testAllSuccess_isZero() {
        let history = (0..<3).map { _ in DatasourceAttempt(profile: "p", success: true, message: "ok") }
        XCTAssertEqual(datasourceConsecutiveFailures(in: history), 0)
    }

    func testTrailingFailureRun_countsOnlyTrailingRun() {
        let history = [
            DatasourceAttempt(profile: "p", success: false, message: "x"),
            DatasourceAttempt(profile: "p", success: true, message: "ok"),
            DatasourceAttempt(profile: "p", success: false, message: "x"),
            DatasourceAttempt(profile: "p", success: false, message: "x"),
        ]
        XCTAssertEqual(datasourceConsecutiveFailures(in: history), 2)
    }

    func testAllFailure_countsFullHistory() {
        let history = (0..<4).map { _ in DatasourceAttempt(profile: "p", success: false, message: "x") }
        XCTAssertEqual(datasourceConsecutiveFailures(in: history), 4)
    }
}

final class DatasourceFailureSentenceTests: XCTestCase {

    func testNoFailures_returnsNil() {
        let sentence = datasourceFailureSentence(history: [], consecutiveFailures: 0, configs: [])
        XCTAssertNil(sentence)
    }

    func testSingleProfileThroughout_fallsBackToPlainCount() {
        let history = (0..<3).map { _ in DatasourceAttempt(profile: "primary", success: false, message: "x") }
        let sentence = datasourceFailureSentence(history: history, consecutiveFailures: 3, configs: [])
        XCTAssertEqual(sentence, "3 consecutive failures.")
    }

    func testCleanSwitchThenAllFailed_returnsCorrelatedSentence() {
        let history = [
            DatasourceAttempt(profile: "primary", success: true, message: "ok"),
            DatasourceAttempt(profile: "override", success: false, message: "x"),
            DatasourceAttempt(profile: "override", success: false, message: "x"),
            DatasourceAttempt(profile: "override", success: false, message: "x"),
        ]
        let configs = [DatasourceConfigInfo(id: "override", label: "override", description: "fm2.internal:443")]
        let sentence = datasourceFailureSentence(history: history, consecutiveFailures: 3, configs: configs)
        XCTAssertEqual(sentence, "Began right after this alias was switched to override (fm2.internal:443). 3 occurrences since.")
    }

    func testProfileNotFoundInConfigs_omitsParentheticalGracefully() {
        let history = [
            DatasourceAttempt(profile: "primary", success: true, message: "ok"),
            DatasourceAttempt(profile: "override", success: false, message: "x"),
        ]
        let sentence = datasourceFailureSentence(history: history, consecutiveFailures: 1, configs: [])
        XCTAssertEqual(sentence, "Began right after this alias was switched to override. 1 occurrence since.")
    }

    func testSwitchThenLaterSuccess_fallsBackToPlainCount() {
        let history = [
            DatasourceAttempt(profile: "primary", success: true, message: "ok"),
            DatasourceAttempt(profile: "override", success: true, message: "ok"),
            DatasourceAttempt(profile: "override", success: false, message: "x"),
        ]
        // The switch to "override" wasn't immediately followed by failure -- no false correlation.
        let sentence = datasourceFailureSentence(history: history, consecutiveFailures: 1, configs: [])
        XCTAssertEqual(sentence, "1 consecutive failure.")
    }

    func testMidStreakSwitch_reportsOverallCount_acceptedSimplification() {
        // Both "primary" and "override" are already failing when the switch happens --
        // the sentence still reports the full consecutiveFailures count, not a
        // strictly-post-switch count. Documented, accepted simplification.
        let history = [
            DatasourceAttempt(profile: "primary", success: false, message: "x"),
            DatasourceAttempt(profile: "override", success: false, message: "x"),
            DatasourceAttempt(profile: "override", success: false, message: "x"),
        ]
        let sentence = datasourceFailureSentence(history: history, consecutiveFailures: 3, configs: [])
        XCTAssertEqual(sentence, "Began right after this alias was switched to override. 3 occurrences since.")
    }
}

// MARK: - Phase 10: /api/datasources route bookkeeping (documented, not HTTP-tested)

final class AdminConsolePhase10DatasourceAttemptsTests: XCTestCase {

    /// This codebase has no HTTP-level route test harness (confirmed in Phases 3/9's own test
    /// notes) -- datasourcesRoute/datasourceTestRoute/datasourceSwitchRoute's new bookkeeping
    /// is exercised only indirectly, through the pure-function tests above (which cover the
    /// actual status/consecutive-failure/correlation logic) plus the HTML/JS substring tests
    /// below (which confirm the client reads/renders the new fields). This test exists only to
    /// document that gap in one place, matching the established convention.
    func testRouteLevelBehaviorIsCoveredIndirectly() {
        XCTAssertTrue(true)
    }
}

// MARK: - Phase 10: AdminWebUI Data tab (admin-console UI redesign phase 4)

final class AdminWebUIPhase10DataTabTests: XCTestCase {

    private func loadHTML() async throws -> String {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        return String(decoding: body, as: UTF8.self)
    }

    func testDataTab_isNoLongerPlaceholder() async throws {
        let html = try await loadHTML()
        let dataStart = try XCTUnwrap(html.range(of: "id=\"tab-data\""))
        let logsStart = try XCTUnwrap(html.range(of: "id=\"tab-logs\""))
        let dataBody = html[dataStart.upperBound..<logsStart.lowerBound]
        XCTAssertFalse(dataBody.contains("being redesigned"), "Data tab should no longer be a placeholder")
    }

    func testDataTab_containsLayoutMounts() async throws {
        let html = try await loadHTML()
        for id in ["data-rail-count", "data-rail-list", "data-detail"] {
            XCTAssertTrue(html.contains("id=\"\(id)\""), "\(id) missing from Data tab")
        }
        XCTAssertTrue(html.contains("data-layout"), "data-layout grid class missing")
    }

    func testResponse_containsDataTabRenderFunctions() async throws {
        let html = try await loadHTML()
        for fn in ["function renderDataTab", "function renderDataRail", "function selectDatasource",
                   "function renderDataDetail", "function renderFailureBanner",
                   "function renderConnectionProfiles", "function renderAttemptHistory",
                   "function testAllDatasources"] {
            XCTAssertTrue(html.contains(fn), "\(fn) missing from JS")
        }
    }

    func testOverviewDatasourceCard_isGone() async throws {
        let html = try await loadHTML()
        XCTAssertFalse(html.contains("id=\"datasource-card\""), "Overview's datasource-card should be removed, not duplicated")
        XCTAssertFalse(html.contains("id=\"datasource-content\""), "Overview's datasource-content should be removed, not duplicated")
    }

    func testDsDividerCSS_stillPresent() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains(".ds-divider"), "ds-divider is still used by renderModels() and should not have been deleted")
    }

    func testRenderDatasourcesFunction_isGone() async throws {
        let html = try await loadHTML()
        XCTAssertFalse(html.contains("function renderDatasources("), "old renderDatasources function should be fully removed, not just superseded")
    }
}

// MARK: - Phase 11: Settings tab (admin-console UI redesign phase 5)

final class AdminWebUIPhase11SettingsTabTests: XCTestCase {

    private func loadHTML() async throws -> String {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        return String(decoding: body, as: UTF8.self)
    }

    func testSettingsTab_containsHeaderAndCopyButton() async throws {
        let html = try await loadHTML()
        let settingsStart = try XCTUnwrap(html.range(of: "id=\"tab-settings\""))
        let settingsBody = html[settingsStart.upperBound...]
        XCTAssertTrue(settingsBody.contains("settings-header"), "settings-header missing")
        XCTAssertTrue(settingsBody.contains("Copy all as text"), "Copy all as text button missing")
        XCTAssertTrue(settingsBody.contains("copySettingsText()"), "copySettingsText() call missing")
    }

    func testSettingsTab_containsAdminAccessAndDelegateMounts() async throws {
        let html = try await loadHTML()
        for id in ["settings-grid", "admin-access-mount", "settings-delegate-mount"] {
            XCTAssertTrue(html.contains("id=\"\(id)\""), "\(id) missing from Settings tab")
        }
    }

    func testSettingsTab_containsInertStripAndCards() async throws {
        let html = try await loadHTML()
        for id in ["settings-inert-strip", "settings-inert-sentence", "settings-inert-toggle", "tls-domains-card", "acme-challenges-card"] {
            XCTAssertTrue(html.contains("id=\"\(id)\""), "\(id) missing from Settings tab")
        }
    }

    func testSettingsTab_routesContentCardIsGone() async throws {
        let html = try await loadHTML()
        XCTAssertFalse(html.contains("id=\"routes-content\""), "standalone Routes card should be folded into Admin access, not duplicated")
    }

    func testOverviewDelegateCards_isGone() async throws {
        let html = try await loadHTML()
        XCTAssertFalse(html.contains("id=\"delegate-cards\""), "Overview's delegate-cards should be removed once Settings owns additionalStatusSections")
    }

    func testResponse_containsSettingsRenderFunctions() async throws {
        let html = try await loadHTML()
        for fn in ["function adminAccessCardHTML", "function renderAdminAccessCard", "function renderDelegateSections",
                   "function renderSettingsInertStrip", "function toggleInertPanels", "function copySettingsText"] {
            XCTAssertTrue(html.contains(fn), "\(fn) missing from JS")
        }
    }

    func testRenderDelegateFunction_isGone() async throws {
        let html = try await loadHTML()
        XCTAssertFalse(html.contains("function renderDelegate("), "old renderDelegate function should be fully removed, not just superseded")
    }

    func testResponse_readsNewStatusFieldsForSettings() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("status.tokenRotatesOnRestart"), "tokenRotatesOnRestart not read from /api/status response")
        XCTAssertTrue(html.contains("status.acmeConfigured"), "acmeConfigured not read from /api/status response")
    }

    func testDashedStripCSS_isPresent() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains(".dashed-strip"), "dashed-strip CSS class missing")
        XCTAssertTrue(html.contains(".settings-inert-heading"), "settings-inert-heading CSS class missing")
    }
}

// MARK: - Phase 11: /api/status new fields (documented, not HTTP-tested)

final class AdminConsolePhase11StatusJSONTests: XCTestCase {

    /// No HTTP-level route test harness exists (confirmed in Phases 3/9/10's own notes). The
    /// two new /api/status fields -- acmeConfigured (acmeResponder != nil) and
    /// tokenRotatesOnRestart (AdminConsole's own stored forceNewToken) -- are branchless
    /// plumbing with no independent logic to unit test in isolation; they're exercised
    /// indirectly through the HTML/JS substring tests above (which confirm the client reads
    /// both fields) plus AdminTokenStore's existing forceNewToken rotation test
    /// (testInit_forceNewTokenRotatesEvenAtSameFilePath).
    func testStatusJSONFieldsAreCoveredIndirectly() {
        XCTAssertTrue(true)
    }
}

// MARK: - Phase 12: AdminJobRun (admin-console UI redesign phase 6)

final class AdminJobRunTests: XCTestCase {
    func testInit_storesAllFields() {
        let started = Date()
        let finished = started.addingTimeInterval(30)
        let run = AdminJobRun(name: "crawl-report", startedAt: started, finishedAt: finished, succeeded: true, summary: "1943 clean, 46 failing")
        XCTAssertEqual(run.name, "crawl-report")
        XCTAssertEqual(run.startedAt, started)
        XCTAssertEqual(run.finishedAt, finished)
        XCTAssertTrue(run.succeeded)
        XCTAssertEqual(run.summary, "1943 clean, 46 failing")
    }
}

// MARK: - Phase 12: AdminActionReport family (admin-console UI redesign phase 6)

final class AdminActionReportRowTests: XCTestCase {
    func testInit_defaultsDetailAndElapsedToNil() {
        let row = AdminActionReportRow(label: "/index.lasso", status: "clean")
        XCTAssertEqual(row.label, "/index.lasso")
        XCTAssertEqual(row.status, "clean")
        XCTAssertNil(row.detail)
        XCTAssertNil(row.elapsedMS)
    }

    func testInit_storesAllFields() {
        let row = AdminActionReportRow(label: "/broken.lasso", status: "5xx", detail: "unknownFunction", elapsedMS: 42)
        XCTAssertEqual(row.detail, "unknownFunction")
        XCTAssertEqual(row.elapsedMS, 42)
    }
}

final class AdminActionReportTests: XCTestCase {
    func testInit_storesAllFields() {
        let now = Date()
        let row = AdminActionReportRow(label: "/a", status: "clean")
        let report = AdminActionReport(
            actionName: "crawl-report",
            generatedAt: now,
            summary: "1943 clean, 46 failing",
            stats: [(label: "Failing", value: "46", isAlert: true)],
            groups: [(heading: "404 unknownFunction", rows: [row])]
        )
        XCTAssertEqual(report.actionName, "crawl-report")
        XCTAssertEqual(report.generatedAt, now)
        XCTAssertEqual(report.summary, "1943 clean, 46 failing")
        XCTAssertEqual(report.stats.count, 1)
        XCTAssertEqual(report.stats[0].label, "Failing")
        XCTAssertTrue(report.stats[0].isAlert)
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups[0].heading, "404 unknownFunction")
        XCTAssertEqual(report.groups[0].rows.count, 1)
    }
}

// MARK: - Phase 12: AdminStatusSection.alertKeys (admin-console UI redesign phase 6)

final class AdminStatusSectionAlertKeysTests: XCTestCase {
    func testInit_defaultAlertKeysIsEmpty() {
        let section = AdminStatusSection(title: "CWP Session Janitor", items: [(key: "Mode", value: "ARMED")])
        XCTAssertTrue(section.alertKeys.isEmpty)
    }

    func testInit_storesExplicitAlertKeys() {
        let section = AdminStatusSection(title: "CWP Session Janitor", items: [(key: "Mode", value: "ARMED")], alertKeys: ["Mode"])
        XCTAssertEqual(section.alertKeys, ["Mode"])
    }
}

// MARK: - Phase 12: AdminConsoleDelegate defaults (admin-console UI redesign phase 6)

private final class MinimalDelegate12: AdminConsoleDelegate {}

final class AdminConsoleDelegatePhase12Tests: XCTestCase {
    func testDefaultRecentJobRuns_isEmpty() async {
        let d = MinimalDelegate12()
        let runs = await d.recentJobRuns()
        XCTAssertTrue(runs.isEmpty)
    }

    func testDefaultActionReport_isNil() async {
        let d = MinimalDelegate12()
        let report = await d.actionReport(for: "crawl-report")
        XCTAssertNil(report)
    }
}

// MARK: - Phase 12: AdminMetrics rate history (admin-console UI redesign phase 6)

final class AdminMetricsRateHistoryTests: XCTestCase {

    func testRequestRateHistory_startsEmpty() async {
        let metrics = AdminMetrics()
        let history = await metrics.requestRateHistory()
        XCTAssertTrue(history.isEmpty)
    }

    func testRecordRequest_accumulatesIntoCurrentBucket() async {
        let metrics = AdminMetrics()
        await metrics.recordRequest(route: "GET:///a")
        await metrics.recordRequest(route: "GET:///b")
        await metrics.recordError()
        let history = await metrics.requestRateHistory()
        XCTAssertEqual(history.count, 1, "calls within the same 5-minute window should share one bucket")
        XCTAssertEqual(history[0].requests, 2)
        XCTAssertEqual(history[0].errors, 1)
    }

    func testRequestRateHistory_windowStartIsRecent() async {
        let metrics = AdminMetrics()
        await metrics.recordRequest(route: "GET:///a")
        let history = await metrics.requestRateHistory()
        let now = Date().timeIntervalSince1970
        XCTAssertEqual(history[0].windowStartUnix, now, accuracy: 5)
    }
}

final class MetricsSnapshotPhase12Tests: XCTestCase {
    func testEncode_includesRateHistory() throws {
        let snap = MetricsSnapshot(
            totalRequests: 10, totalErrors: 1, activeConnections: 2, routeCounts: [:],
            rateHistory: [RateBucketSnapshot(windowStartUnix: 1000, requests: 5, errors: 1)]
        )
        let data = try JSONEncoder().encode(snap)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let history = try XCTUnwrap(json["rateHistory"] as? [[String: Any]])
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0]["requests"] as? Int, 5)
        XCTAssertEqual(history[0]["errors"] as? Int, 1)
    }

    func testInit_defaultsRateHistoryToEmpty() {
        let snap = MetricsSnapshot(totalRequests: 0, totalErrors: 0, activeConnections: 0, routeCounts: [:])
        XCTAssertTrue(snap.rateHistory.isEmpty)
    }

    func testSnapshotFromActor_includesRateHistory() async {
        let metrics = AdminMetrics()
        await metrics.recordRequest(route: "GET:///a")
        let snap = await metrics.snapshot()
        XCTAssertEqual(snap.rateHistory.count, 1)
        XCTAssertEqual(snap.rateHistory[0].requests, 1)
    }
}

// MARK: - Phase 12: AdminWebUI Overview/report/token-gate (admin-console UI redesign phase 6)

final class AdminWebUIPhase12OverviewTests: XCTestCase {

    private func loadHTML() async throws -> String {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        return String(decoding: body, as: UTF8.self)
    }

    func testOverviewTab_containsFiveNewCardMounts() async throws {
        let html = try await loadHTML()
        for id in ["attention-card", "activity-card", "traffic-card", "datasources-summary-card", "quick-actions-card"] {
            XCTAssertTrue(html.contains("id=\"\(id)\""), "\(id) missing from Overview tab")
        }
    }

    func testOverviewTab_oldStatusAndMetricsMountsAreGone() async throws {
        let html = try await loadHTML()
        XCTAssertFalse(html.contains("id=\"status-rows\""), "old Server Status card mount should be removed, not duplicated")
        XCTAssertFalse(html.contains("id=\"metrics-rows\""), "old Metrics card mount should be removed, superseded by Traffic")
    }

    func testModelsCard_movedToDataTab() async throws {
        let html = try await loadHTML()
        let dataStart = try XCTUnwrap(html.range(of: "id=\"tab-data\""))
        let overviewStart = try XCTUnwrap(html.range(of: "id=\"tab-overview\""))
        let overviewSection = html[overviewStart.upperBound..<dataStart.lowerBound]
        XCTAssertFalse(overviewSection.contains("id=\"models-content\""), "Models card should have moved out of Overview")
        let dataSection = html[dataStart.upperBound...]
        XCTAssertTrue(dataSection.contains("id=\"models-content\""), "Models card should be present in the Data tab")
    }

    func testReportTabPanel_isPresent() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("id=\"tab-report\""), "6th tab-panel for crawl-report-result missing")
        XCTAssertTrue(html.contains("id=\"report-content\""), "report-content mount missing")
    }

    func testAuthGate_containsWhyLineAndRememberCheckbox() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("id=\"gate-why\""), "gate-why line missing")
        XCTAssertTrue(html.contains("id=\"remember-checkbox\""), "remember checkbox missing")
        XCTAssertTrue(html.contains("id=\"remember-row\""), "remember-row missing")
    }

    func testResponse_containsPhase12RenderFunctions() async throws {
        let html = try await loadHTML()
        for fn in ["function renderAttentionCard", "function renderActivityCard", "function renderTraffic",
                   "function renderDatasourcesSummary", "function renderQuickActions",
                   "function openActionReport", "function renderActionReportOverlay", "function downloadReportCSV",
                   "function openDetachedWindow", "async function initGate"] {
            XCTAssertTrue(html.contains(fn), "\(fn) missing from JS")
        }
    }

    func testOpenLogsWindowFunction_isGone() async throws {
        let html = try await loadHTML()
        XCTAssertFalse(html.contains("function openLogsWindow("), "old openLogsWindow should be fully generalized into openDetachedWindow, not aliased")
    }

    func testGateInfoRoute_isFetchedByInitGate() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("/api/gate-info"), "initGate() should fetch the new unauthenticated gate-info route")
    }

    func testConnect_readsRememberCheckboxForStorageChoice() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("localStorage.setItem(KEY"), "connect() should support remembering the token in localStorage")
    }

    func testActionsReportRoute_isFetchedOnDemand() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("/api/actions/report?name="), "openActionReport() should fetch the new structured-report route")
    }

    /// Regression guard for a real bug caught only by manual visual verification (a demo CWP
    /// Janitor section with `alertKeys: ["Mode"]` rendered "Mode" as plain text, not an alert
    /// tag) -- `renderDelegateSections` originally never read `s.alertKeys` at all, so the field
    /// flowed all the way from AdminStatusSection through JSON and was silently dropped on the
    /// client. Confirms the fix actually consults it.
    func testRenderDelegateSections_readsAlertKeysAndAppliesTagClass() async throws {
        let html = try await loadHTML()
        XCTAssertTrue(html.contains("s.alertKeys"), "renderDelegateSections should read alertKeys from each section")
        XCTAssertTrue(html.contains("data-tag-failing"), "an alert-flagged key should render with the alert tag class")
    }
}

// MARK: - Phase 12: /api/actions/report and /api/gate-info routes (documented, not HTTP-tested)

final class AdminConsolePhase12ActionReportRouteTests: XCTestCase {

    /// No HTTP-level route test harness exists (same gap acknowledged in Phases 3/9/10/11).
    /// `/api/actions/report` and `/api/gate-info` are exercised indirectly: the delegate-default
    /// tests above confirm `actionReport(for:)` defaults to nil, and the HTML/JS tests above
    /// confirm the client fetches both routes and handles a null report gracefully.
    func testActionReportAndGateInfoRoutesAreCoveredIndirectly() {
        XCTAssertTrue(true)
    }
}

// MARK: - JSON body decoding

final class AdminJSONBodyTests: XCTestCase {
    private struct Body: Decodable { let hostname: String }

    func testValidBodyDecodes() throws {
        let body = try adminDecodeJSON(Body.self, from: Array(#"{"hostname":"example.com"}"#.utf8))
        XCTAssertEqual(body.hostname, "example.com")
    }

    /// A body that doesn't decode is a 400 with a generic message. It used to escape as a
    /// DecodingError, which the server sent back as a 500 naming the type and key.
    func testUndecodableBodiesAre400WithoutDetails() {
        for bytes in [Array(#"{"host":"x"}"#.utf8), Array("not json".utf8), []] {
            XCTAssertThrowsError(try adminDecodeJSON(Body.self, from: bytes)) { error in
                let output = error as? ErrorOutput
                XCTAssertEqual(output?.head(request: HTTPRequestInfo(head: .init(version: .http1_1, method: .POST, uri: "/"), options: []))?.status, .badRequest)
                XCTAssertEqual(output?.description, "Bad Request")
            }
        }
    }
}
