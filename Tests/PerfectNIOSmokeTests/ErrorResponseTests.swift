//
//  ErrorResponseTests.swift
//  PerfectNIOSmokeTests
//
//  What clients see when a route throws: request decoding failures are 400s,
//  other unexpected errors are generic 500s, and neither echoes the error's
//  description (Swift type names, key paths, whatever the error carries).
//

import Testing
import Foundation
@testable import PerfectNIO

private struct Payload: Codable, Sendable {
    let count: Int
    let label: String
}

private struct InternalFailure: Error, CustomStringConvertible {
    var description: String { "connection to db-primary.internal:5432 refused for user app_rw" }
}

private func exchange(_ routes: Routes<HTTPRequest, HTTPOutput>,
                      _ request: [UInt8]) async throws -> RawHTTPResponse {
    try await Server(routes: routes, port: 0).withServer { port in
        await rawHTTP(port: port, [request])
    }
}

private func post(_ path: String, contentType: String, body: String) -> [UInt8] {
    rawHead("POST", path, [("Content-Type", contentType), ("Content-Length", "\(body.utf8.count)"),
                           ("Connection", "close")]) + Array(body.utf8)
}

private let decodeRoute = root().POST.path("p").decode(Payload.self) { "\($0.count) \($0.label)" }.text()

/// Fragments of the DecodingError text that main sent back in the 500 body.
private let leakedFragments = ["Payload", "count", "label", "keyNotFound", "dataCorrupted",
                               "typeMismatch", "Could not convert", "CodingKeys", "Int"]

@Suite("Error responses")
struct ErrorResponseTests {

    @Test func decodingStillWorks() async throws {
        let r = try await exchange(decodeRoute, post("/p", contentType: "application/x-www-form-urlencoded",
                                                     body: "count=3&label=hi"))
        #expect(r.status == 200)
        #expect(r.body == "3 hi")
    }

    /// On main each of these was a 500 whose body was the DecodingError's description.
    @Test(arguments: [
        ("application/x-www-form-urlencoded", "label=hi"),          // missing key
        ("application/x-www-form-urlencoded", "count=abc&label=hi"), // won't convert
        ("application/json", #"{"count": 1}"#),                    // missing key
        ("application/json", #"{"count": "one", "label": "x"}"#),  // wrong type
        ("application/json", "{not json"),                           // malformed
    ])
    func requestDecodingFailuresAre400WithoutDetails(contentType: String, body: String) async throws {
        let r = try await exchange(decodeRoute, post("/p", contentType: contentType, body: body))
        #expect(r.status == 400)
        #expect(r.body == "Bad Request")
        for fragment in leakedFragments {
            #expect(!r.body.contains(fragment), "response body leaks \(fragment)")
        }
    }

    @Test func queryArgumentDecodingFailuresAre400() async throws {
        let routes = root().GET.path("q").decode(Payload.self) { "\($0.count)" }.text()
        let r = try await exchange(routes, rawHead("GET", "/q?count=x&label=y", [("Connection", "close")]))
        #expect(r.status == 400)
        #expect(r.body == "Bad Request")
    }

    /// On main the body was "Internal server error: " plus the error's description.
    @Test func unexpectedErrorsAreGeneric500s() async throws {
        let routes = root().GET.path("boom").map { () throws -> String in throw InternalFailure() }.text()
        let r = try await exchange(routes, rawHead("GET", "/boom", [("Connection", "close")]))
        #expect(r.status == 500)
        #expect(r.body == "Internal server error.")
        #expect(!r.body.contains("db-primary"))
    }

    /// A DecodingError that isn't from decoding the request (here, the handler decoding its own
    /// data) is a server fault, so it stays a 500, also without the detail.
    @Test func decodingErrorsFromHandlersAre500s() async throws {
        let routes = root().GET.path("own").map { () throws -> String in
            try JSONDecoder().decode(Payload.self, from: Data("{}".utf8)).label
        }.text()
        let r = try await exchange(routes, rawHead("GET", "/own", [("Connection", "close")]))
        #expect(r.status == 500)
        #expect(r.body == "Internal server error.")
    }

    /// ErrorOutput is the way to choose what the client sees, so it's still passed through.
    @Test func errorOutputIsSentAsIs() async throws {
        let routes = root().GET.path("conflict").map { () throws -> String in
            throw ErrorOutput(status: .conflict, description: "Name already taken.")
        }.text()
        let r = try await exchange(routes, rawHead("GET", "/conflict", [("Connection", "close")]))
        #expect(r.status == 409)
        #expect(r.body == "Name already taken.")
    }

    @Test func terminationErrorIsSentAsIs() async throws {
        let routes = root().GET.path("t").map { () throws -> String in
            throw TerminationType.error(ErrorOutput(status: .forbidden, description: "Nope."))
        }.text()
        let r = try await exchange(routes, rawHead("GET", "/t", [("Connection", "close")]))
        #expect(r.status == 403)
        #expect(r.body == "Nope.")
    }
}
