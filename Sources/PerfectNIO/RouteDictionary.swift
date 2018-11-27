//
//  RouteDictionary.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-10-23.
//

import Foundation
import PerfectCRUD
import NIOConcurrencyHelpers
import NIOHTTP1

protocol RouteFinder {
	typealias ResolveFunc = (Future<RouteValueBox<HTTPRequest>>) throws -> Future<RouteValueBox<HTTPOutput>>
	init(_ registry: Routes<HTTPRequest, HTTPOutput>) throws
	subscript(_ method: HTTPMethod, _ uri: String) -> ResolveFunc? { get }
}

extension RouteRegistry {
	var withMethods: RouteRegistry {
		return .init(routes: routes.flatMap {
			item -> [RouteRegistry.Tuple] in
			let (method, path) = item.0.splitMethod
			if nil == method {
				let r = item.1
				return HTTPMethod.allCases.map {
					("\($0)://\(path)", r)
				}
			}
			return [item]
		})
	}
}

class RouteFinderRegExp: RouteFinder {
	typealias Matcher = (NSRegularExpression, ResolveFunc)
	let matchers: [HTTPMethod:[Matcher]]
	required init(_ registry: Routes<HTTPRequest, HTTPOutput>) throws {
		let full = registry.registry.withMethods.routes
		var m = [HTTPMethod:[Matcher]]()
		try full.forEach {
			let (p1, fnc) = $0
			let (meth, path) = p1.splitMethod
			let method = meth ?? .GET
			let matcher: Matcher = (try RouteFinderRegExp.regExp(for: path), fnc)
			let fnd = m[method] ?? []
			m[method] = fnd + [matcher]
		}
		matchers = m
	}
	subscript(_ method: HTTPMethod, _ uri: String) -> ResolveFunc? {
		guard let matchers = self.matchers[method] else {
			return nil
		}
		let uriRange = NSRange(location: 0, length: uri.count)
		for i in 0..<matchers.count {
			let matcher = matchers[i]
			guard let _ = matcher.0.firstMatch(in: uri, range: uriRange) else {
				continue
			}
			return matcher.1
		}
		return nil
	}
	static func regExp(for path: String) throws -> NSRegularExpression {
		let c = path.components
		let strs = c.map {
			comp -> String in
			switch comp {
			case "*":
				return "/([^/]*)"
			case "**":
				return "/(.*)"
			default:
				return "/" + comp
			}
		}
		return try NSRegularExpression(pattern: "^" + strs.joined(separator: "") + "$", options: NSRegularExpression.Options.caseInsensitive)
	}
}

class RouteFinderDictionary: RouteFinder {
	let dict: [String:ResolveFunc]
	required init(_ registry: Routes<HTTPRequest, HTTPOutput>) throws {
		dict = Dictionary(registry.registry.withMethods.routes.filter {
			!($0.0.components.contains("*") || $0.0.components.contains("**"))
		}, uniquingKeysWith: {return $1})
	}
	subscript(_ method: HTTPMethod, _ uri: String) -> ResolveFunc? {
		let key = method.name + "://" + uri
		return dict[key]
	}
}

class RouteFinderDual: RouteFinder {
	let alpha: RouteFinder
	let beta: RouteFinder
	required init(_ registry: Routes<HTTPRequest, HTTPOutput>) throws {
		alpha = try RouteFinderDictionary(registry)
		beta = try RouteFinderRegExp(registry)
	}
	
	subscript(_ method: HTTPMethod, _ uri: String) -> ResolveFunc? {
		return alpha[method, uri] ?? beta[method, uri]
	}
}
