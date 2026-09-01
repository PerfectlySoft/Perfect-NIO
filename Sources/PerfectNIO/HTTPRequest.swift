//
//  HTTPRequest.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2019-02-11.
//

import NIO
import NIOHTTP1
import Foundation

/// Client content which has been read and parsed (if needed).
public enum HTTPRequestContentType {
	/// There was no content provided by the client.
	case none
	/// A multi-part form/file upload.
	case multiPartForm(MimeReader)
	/// A url-encoded form.
	case urlForm(QueryDecoder)
	/// Some other sort of content.
	case other([UInt8])
}

public protocol HTTPRequest: AnyObject {
	var channel: Channel? { get }
	var method: HTTPMethod { get }
	var uri: String { get }
	var headers: HTTPHeaders { get }
	var uriVariables: [String: String] { get set }
	var path: String { get }
	var searchArgs: QueryDecoder? { get }
	var contentType: String? { get }
	var contentLength: Int { get }
	var contentRead: Int { get }
	var contentConsumed: Int { get }
	var localAddress: SocketAddress? { get }
	var remoteAddress: SocketAddress? { get }
	func readSomeContent() async throws -> [ByteBuffer]
	func readContent() async throws -> HTTPRequestContentType
}

public extension HTTPRequest {
	/// Returns all cookie name/value pairs parsed from the request.
	var cookies: [String: String] {
		guard let cookie = self.headers["cookie"].first else {
			return [:]
		}
		return Dictionary(cookie.split(separator: ";").compactMap { pair -> (String, String)? in
			// `maxSplits: 1` is required, not cosmetic: an unlimited split
			// on every "=" (the previous behavior) had two distinct real
			// failure modes for any value containing an "=" -- extremely
			// common for base64-encoded/padded or token-style cookies.
			// (1) A value with a non-empty segment past the first "="
			// (e.g. "a=b=c") produced 3+ parts, failed the `d.count == 2`
			// guard, and the *entire* cookie silently vanished. (2) A
			// value ending in base64 "=" padding (e.g. "dGVzdA==") was
			// worse: `split(separator:)` omits empty subsequences by
			// default, so the trailing padding collapsed away entirely
			// and `d.count` came back as exactly 2 anyway -- the cookie
			// survived but with its value silently corrupted/truncated,
			// never raising any error. Only the first "=" actually
			// delimits name from value; everything after it belongs to
			// the value verbatim.
			let d = pair.split(separator: "=", maxSplits: 1)
			guard d.count == 2 else { return nil }
			// Trim only the whitespace the "; " pair-separator convention
			// introduces at each subsequent name's start -- stripping
			// every space unconditionally (the previous behavior) would
			// also corrupt any value containing a legitimate internal
			// space.
			let name = String(d[0]).trimmingCharacters(in: .whitespaces)
			guard let decodedName = name.stringByDecodingURL,
			      let decodedValue = String(d[1]).stringByDecodingURL else {
				return nil
			}
			return (decodedName, decodedValue)
		}, uniquingKeysWith: { $1 })
	}
}
