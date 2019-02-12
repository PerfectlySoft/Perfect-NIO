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

import Foundation

@_exported import NIO
@_exported import NIOHTTP1
@_exported import NIOOpenSSL
@_exported import CNIOOpenSSL

public typealias ComponentGenerator = IndexingIterator<[String]>

extension String {
	var components: [String] {
		return self.split(separator: "/").map(String.init)
	}
	var componentGenerator: ComponentGenerator {
		return self.split(separator: "/").map(String.init).makeIterator()
	}
	// need url decoding component generator
	func appending(component name: String) -> String {
		let name = name.components.joined(separator: "/")
		if name.isEmpty {
			return self
		}
		if hasSuffix("/") {
			return self + name
		}
		return self + "/" + name.split(separator: "/").joined(separator: "/")
	}
	var cleanedPath: String {
		return "/" + components.joined(separator: "/")
	}
	var componentBase: String? {
		return self.components.first
	}
	var componentName: String? {
		return self.components.last
	}
	var ext: String {
		if self.first != "." {
			return "." + self
		}
		return self
	}
	var splitQuery: (String, String?) {
		guard let r = self.range(of: "?") else {
			return (self, nil)
		}
		return (String(self[self.startIndex..<r.lowerBound]), String(self[r.upperBound...]))
	}
	var decodedQuery: [(String, String)] {
		var ret: [(String, String)] = []
		let ampChar = "&"
		let eqChar = "="
		var pos: String.Index = startIndex
		let end = endIndex
		
		func makeTuple(_ range: Range<String.Index>) -> (String, String) {
			guard let r = self.range(of: eqChar, range: range) else {
				return (String(self[range]), "")
			}
			return (String(self[range.lowerBound..<r.lowerBound]).stringByDecodingURL ?? "",
					String(self[r.upperBound..<range.upperBound]).stringByDecodingURL ?? "")
		}
		while let amp = range(of: ampChar, range: pos..<end) {
			ret.append(makeTuple(pos..<amp.lowerBound))
			pos = amp.upperBound
		}
		if pos < end {
			ret.append(makeTuple(pos..<end))
		}
		return ret
	}
	var splitUri: (String, [(String, String)]) {
		let s1 = splitQuery
		return (s1.0, s1.1?.decodedQuery ?? [])
	}
}

public enum TerminationType: Error {
	case error(ErrorOutput)
	case criteriaFailed
	case internalError
}
