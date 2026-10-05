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
	typealias ResolvedRoute = Routes<HTTPRequest, HTTPOutput>.Route
	init(_ registry: Routes<HTTPRequest, HTTPOutput>) throws
	/// The route matching `method` and `uri`, including whether it is a WebSocket endpoint.
	func route(_ method: HTTPMethod, _ uri: String) -> ResolvedRoute?
}

extension RouteFinder {
	subscript(_ method: HTTPMethod, _ uri: String) -> ResolveFunc? {
		route(method, uri)?.handler
	}
}

// Expand method-less routes to one entry per HTTP method.
extension Routes {
	var withMethods: [String: Route] {
		var result: [String: Route] = [:]
		for (key, route) in routes {
			let (method, path) = key.splitMethod
			if method == nil {
				for m in HTTPMethod.allCases {
					result["\(m.name)://\(path)"] = route
				}
			} else {
				result[key] = route
			}
		}
		return result
	}
}

class RouteFinderRegExp: RouteFinder, @unchecked Sendable {
	typealias Matcher = (NSRegularExpression, ResolvedRoute)
	let matchers: [HTTPMethod: [Matcher]]
	required init(_ registry: Routes<HTTPRequest, HTTPOutput>) throws {
		let full = registry.withMethods
		var m = [HTTPMethod: [Matcher]]()
		try full.forEach { key, route in
			let (meth, path) = key.splitMethod
			let method = meth ?? .GET
			let matcher: Matcher = (try RouteFinderRegExp.regExp(for: path), route)
			let existing = m[method] ?? []
			m[method] = existing + [matcher]
		}
		matchers = m
	}
	func route(_ method: HTTPMethod, _ uri: String) -> ResolvedRoute? {
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
	let dict: [String: ResolvedRoute]
	required init(_ registry: Routes<HTTPRequest, HTTPOutput>) throws {
		dict = registry.withMethods.filter {
			!($0.key.components.contains("*") || $0.key.components.contains("**"))
		}
	}
	func route(_ method: HTTPMethod, _ uri: String) -> ResolvedRoute? {
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
	func route(_ method: HTTPMethod, _ uri: String) -> ResolvedRoute? {
		alpha.route(method, uri) ?? beta.route(method, uri)
	}
}
