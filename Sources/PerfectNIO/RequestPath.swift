//
//  RequestPath.swift
//  PerfectNIO
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2019 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

enum RequestPath {
	/// True if the request target has a "#" (a fragment, which a conforming client never sends;
	/// routing doesn't treat it specially, so it must not hide path text from the check below).
	static func hasFragment(_ uri: String) -> Bool {
		uri.utf8.contains(UInt8(ascii: "#"))
	}

	/// True if the path part of `uri` (everything before the first "?", exactly the text the
	/// router uses) has a ".." segment, as sent or after percent-decoding (repeated until
	/// nothing changes, so nested encodings are caught), with "/" and "\\" both treated as
	/// separators, so "%2e%2e", ".%2e", "..%2f", "..%5c" and "..\\" all count. A segment also
	/// counts if it is ".." followed by ";" (a path parameter, "..;jsessionid=") or a NUL.
	/// Such a request is refused before routing, so `wild` and `trailing` never hand a handler
	/// a traversal segment. A segment that merely contains dots ("a..b", ".hidden", "...") is
	/// fine.
	///
	/// Decoding stops after `maxDecodingPasses`; a path that still changes then (more nested
	/// encoding than any real client sends) counts as a traversal. Each pass is linear, so the
	/// check is too. (Decoding until stable, one layer per pass, was quadratic: an 80 KB URI of
	/// nested "%25" cost seconds of CPU.)
	static func hasDotDotSegment(_ uri: String) -> Bool {
		var bytes = Array(uri.utf8.prefix { $0 != UInt8(ascii: "?") })
		for _ in 0..<maxDecodingPasses {
			if hasDotDotSegment(bytes: bytes) { return true }
			let decoded = percentDecoded(bytes)
			if decoded == bytes { return false }
			bytes = decoded
		}
		return true
	}

	/// How many layers of percent-encoding are undone before giving up.
	static let maxDecodingPasses = 8

	/// The longest request target accepted; longer ones get 414 before anything else looks at
	/// them. (nginx's default limit is the same order: 8 KiB header lines.)
	static let maxRequestTargetLength = 8 * 1024

	private static func hasDotDotSegment(bytes: [UInt8]) -> Bool {
		bytes.split(omittingEmptySubsequences: false) { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "\\") }
			.contains { segment in
				let name = segment.prefix { $0 != UInt8(ascii: ";") && $0 != 0 }
				return name.elementsEqual([UInt8(ascii: "."), UInt8(ascii: ".")])
			}
	}

	/// Decodes valid %XX escapes and leaves anything else (an invalid escape) as it is.
	private static func percentDecoded(_ bytes: [UInt8]) -> [UInt8] {
		func hex(_ b: UInt8) -> UInt8? {
			switch b {
			case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
			case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
			case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
			default: return nil
			}
		}
		var out: [UInt8] = []
		out.reserveCapacity(bytes.count)
		var i = 0
		while i < bytes.count {
			if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count, let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) {
				out.append(hi << 4 | lo)
				i += 3
			} else {
				out.append(bytes[i])
				i += 1
			}
		}
		return out
	}
}
