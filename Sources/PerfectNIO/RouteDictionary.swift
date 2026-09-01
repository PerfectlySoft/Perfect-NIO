//
//  RouteDictionary.swift
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

import Foundation
import NIOCore
import NIOHTTP1

protocol RouteFinder: Sendable {
	typealias ResolveFunc = @Sendable (RouteContext, any HTTPRequest) async throws -> (RouteContext, HTTPOutput)
	init(_ registry: Routes<HTTPRequest, HTTPOutput>) throws
	subscript(_ method: HTTPMethod, _ uri: String) -> ResolveFunc? { get }
}

// Expand method-less routes to one entry per HTTP method.
extension Routes {
	var withMethods: [String: Handler] {
		var result: [String: Handler] = [:]
		for (key, handler) in routes {
			let (method, path) = key.splitMethod
			if method == nil {
				for m in HTTPMethod.allCases {
					result["\(m.name)://\(path)"] = handler
				}
			} else {
				result[key] = handler
			}
		}
		return result
	}
}

class RouteFinderRegExp: RouteFinder, @unchecked Sendable {
	typealias Matcher = (NSRegularExpression, ResolveFunc)
	let matchers: [HTTPMethod: [Matcher]]
	required init(_ registry: Routes<HTTPRequest, HTTPOutput>) throws {
		let full = registry.withMethods
		var m = [HTTPMethod: [Matcher]]()
		try full.forEach { key, fnc in
			let (meth, path) = key.splitMethod
			let method = meth ?? .GET
			let matcher: Matcher = (try RouteFinderRegExp.regExp(for: path), fnc)
			let existing = m[method] ?? []
			m[method] = existing + [matcher]
		}
		matchers = m
	}
	subscript(_ method: HTTPMethod, _ uri: String) -> ResolveFunc? {
		guard let matchers = self.matchers[method] else { return nil }
		let uriRange = NSRange(location: 0, length: uri.count)
		for matcher in matchers {
			guard matcher.0.firstMatch(in: uri, range: uriRange) != nil else { continue }
			return matcher.1
		}
		return nil
	}
	static func regExp(for path: String) throws -> NSRegularExpression {
		let strs = path.components.map { comp -> String in
			switch comp {
			case "*":  return "/([^/]*)"
			case "**": return "/(.*)"
			default:   return "/" + comp
			}
		}
		return try NSRegularExpression(pattern: "^" + strs.joined(separator: "") + "$",
		                               options: .caseInsensitive)
	}
}

class RouteFinderDictionary: RouteFinder, @unchecked Sendable {
	let dict: [String: ResolveFunc]
	required init(_ registry: Routes<HTTPRequest, HTTPOutput>) throws {
		dict = registry.withMethods.filter {
			!($0.key.components.contains("*") || $0.key.components.contains("**"))
		}
	}
	subscript(_ method: HTTPMethod, _ uri: String) -> ResolveFunc? {
		dict[method.name + "://" + uri]
	}
}

class RouteFinderDual: RouteFinder, @unchecked Sendable {
	let alpha: any RouteFinder
	let beta: any RouteFinder
	required init(_ registry: Routes<HTTPRequest, HTTPOutput>) throws {
		alpha = try RouteFinderDictionary(registry)
		beta = try RouteFinderRegExp(registry)
	}
	subscript(_ method: HTTPMethod, _ uri: String) -> ResolveFunc? {
		alpha[method, uri] ?? beta[method, uri]
	}
}
