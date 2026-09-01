//
//  RouteRegistry.swift
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

import NIO
import NIOHTTP1

/// An error occurring while building a route set.
public enum RouteError: Error, CustomStringConvertible {
	case duplicatedRoutes([String])
	public var description: String {
		switch self {
		case .duplicatedRoutes(let r):
			return "Duplicated routes: \(r.joined(separator: ", "))"
		}
	}
}

@resultBuilder
public struct RouteBuilder<InType, OutType> {
	public typealias RouteType = Routes<InType, OutType>
	// buildExpression wraps each route in an array (the component type).
	public static func buildExpression(_ expression: RouteType) -> [RouteType] { [expression] }
	// buildBlock receives [RouteType] components (one per expression) and joins them.
	public static func buildBlock(_ children: [RouteType]...) -> [RouteType] { Array(children.joined()) }
	public static func buildBlock() -> [RouteType] { [] }
}

/// Main routes object. Created by calling `root()` or by chaining a builder method.
@dynamicMemberLookup
public struct Routes<InType, OutType> {
	typealias Handler = @Sendable (RouteContext, InType) async throws -> (RouteContext, OutType)
	var routes: [String: Handler]

	init(_ routes: [String: Handler]) {
		self.routes = routes
	}

	func applyPaths(_ call: @escaping (String) -> String) -> Routes {
		.init(Dictionary(routes.map { (call($0.key), $0.value) }, uniquingKeysWith: { $1 }))
	}

	func applyFuncs<NewOut>(
		_ call: @Sendable @escaping (RouteContext, OutType) async throws -> (RouteContext, NewOut)
	) -> Routes<InType, NewOut> {
		.init(Dictionary(routes.map { key, existing in
			let h: Routes<InType, NewOut>.Handler = { ctx, input in
				let (midCtx, midOut) = try await existing(ctx, input)
				return try await call(midCtx, midOut)
			}
			return (key, h)
		}, uniquingKeysWith: { $1 }))
	}

	func apply<NewOut>(
		paths: @escaping (String) -> String,
		funcs call: @Sendable @escaping (RouteContext, OutType) async throws -> (RouteContext, NewOut)
	) -> Routes<InType, NewOut> {
		.init(Dictionary(routes.map { key, existing in
			let h: Routes<InType, NewOut>.Handler = { ctx, input in
				let (midCtx, midOut) = try await existing(ctx, input)
				return try await call(midCtx, midOut)
			}
			return (paths(key), h)
		}, uniquingKeysWith: { $1 }))
	}
}

// Safe: the only stored property is `routes: [String: Handler]`, and `Handler` is a
// `@Sendable` function type — so a `Routes` value is just Sendable closures + String keys,
// regardless of `InType`/`OutType` (which appear only in the closure signatures).
extension Routes: @unchecked Sendable {}

// MARK: - Root constructors

/// Create a root route that passes the HTTPRequest through unchanged.
public func root() -> Routes<HTTPRequest, HTTPRequest> {
	.init(["/": { ctx, req in (ctx, req) }])
}

/// Create a root route that accepts the HTTPRequest and maps it to a new value.
public func root<NewOut>(_ call: @Sendable @escaping (HTTPRequest) async throws -> NewOut) -> Routes<HTTPRequest, NewOut> {
	.init(["/": { ctx, req in (ctx, try await call(req)) }])
}

/// Create a root route that ignores the HTTPRequest and produces a new value.
public func root<NewOut>(_ call: @Sendable @escaping () async throws -> NewOut) -> Routes<HTTPRequest, NewOut> {
	.init(["/": { ctx, _ in (ctx, try await call()) }])
}

/// Create a root route for use inside `dir` chains.
public func root<NewOut>(path: String, _ type: NewOut.Type) -> Routes<NewOut, NewOut> {
	.init([path: { ctx, input in (ctx, input) }])
}

// MARK: - map

public extension Routes {
	func map<NewOut>(_ call: @Sendable @escaping (OutType) async throws -> NewOut) -> Routes<InType, NewOut> {
		applyFuncs { ctx, output in (ctx, try await call(output)) }
	}
	func map<NewOut>(_ call: @Sendable @escaping () async throws -> NewOut) -> Routes<InType, NewOut> {
		applyFuncs { ctx, _ in (ctx, try await call()) }
	}
	func map<NewOut>(_ call: @Sendable @escaping (OutType.Element) async throws -> NewOut) -> Routes<InType, [NewOut]> where OutType: Collection {
		applyFuncs { ctx, output in
			var results: [NewOut] = []
			results.reserveCapacity(output.underestimatedCount)
			for element in output {
				results.append(try await call(element))
			}
			return (ctx, results)
		}
	}
}

// MARK: - @dynamicMemberLookup

public extension Routes {
	subscript(dynamicMember name: String) -> Routes {
		path(name)
	}
	subscript<NewOut>(dynamicMember name: String) -> (@Sendable @escaping (OutType) async throws -> NewOut) -> Routes<InType, NewOut> {
		{ self.path(name, $0) }
	}
	subscript<NewOut>(dynamicMember name: String) -> (@Sendable @escaping () async throws -> NewOut) -> Routes<InType, NewOut> {
		{ call in self.path(name, { _ in try await call() }) }
	}
}

// MARK: - path

public extension Routes {
	func path(_ name: String) -> Routes {
		apply(paths: { $0.appending(component: name) }) { ctx, output in
			var newCtx = ctx; newCtx.advanceComponent()
			return (newCtx, output)
		}
	}
	func path<NewOut>(_ name: String, _ call: @Sendable @escaping (OutType) async throws -> NewOut) -> Routes<InType, NewOut> {
		apply(paths: { $0.appending(component: name) }) { ctx, output in
			var newCtx = ctx; newCtx.advanceComponent()
			return (newCtx, try await call(output))
		}
	}
	func path<NewOut>(_ name: String, _ call: @Sendable @escaping () async throws -> NewOut) -> Routes<InType, NewOut> {
		apply(paths: { $0.appending(component: name) }) { ctx, output in
			var newCtx = ctx; newCtx.advanceComponent()
			return (newCtx, try await call())
		}
	}
}

// MARK: - ext

public extension Routes {
	func ext(_ ext: String) -> Routes {
		applyPaths { $0 + ext.ext }
	}
	func ext(_ ext: String, contentType: String) -> Routes {
		apply(paths: { $0 + ext.ext }) { ctx, output in
			var newCtx = ctx
			newCtx.responseHeaders.add(name: "content-type", value: contentType)
			return (newCtx, output)
		}
	}
	func ext<NewOut>(_ ext: String, contentType: String? = nil, _ call: @Sendable @escaping (OutType) async throws -> NewOut) -> Routes<InType, NewOut> {
		apply(paths: { $0 + ext.ext }) { ctx, output in
			var newCtx = ctx
			if let c = contentType { newCtx.responseHeaders.add(name: "content-type", value: c) }
			return (newCtx, try await call(output))
		}
	}
}

// MARK: - wild / trailing

public extension Routes {
	func wild<NewOut>(_ call: @Sendable @escaping (OutType, String) async throws -> NewOut) -> Routes<InType, NewOut> {
		apply(paths: { $0.appending(component: "*") }) { ctx, output in
			let component = ctx.currentComponent ?? "-error-"
			var newCtx = ctx; newCtx.advanceComponent()
			return (newCtx, try await call(output, component))
		}
	}
	func wild(name: String) -> Routes {
		apply(paths: { $0.appending(component: "*") }) { ctx, output in
			var newCtx = ctx
			let component = ctx.currentComponent ?? "-error-"
			newCtx.uriVariables[name] = component
			ctx.request.uriVariables[name] = component
			newCtx.advanceComponent()
			return (newCtx, output)
		}
	}
	func trailing<NewOut>(_ call: @Sendable @escaping (OutType, String) async throws -> NewOut) -> Routes<InType, NewOut> {
		apply(paths: { $0.appending(component: "**") }) { ctx, output in
			let trailing = ctx.trailingComponents
			var newCtx = ctx; newCtx.advanceComponent()
			return (newCtx, try await call(output, trailing))
		}
	}
}

// MARK: - request / readBody

public extension Routes {
	func request<NewOut>(_ call: @Sendable @escaping (OutType, any HTTPRequest) async throws -> NewOut) -> Routes<InType, NewOut> {
		applyFuncs { ctx, output in (ctx, try await call(output, ctx.request)) }
	}
	func readBody<NewOut>(_ call: @Sendable @escaping (OutType, HTTPRequestContentType) async throws -> NewOut) -> Routes<InType, NewOut> {
		applyFuncs { ctx, output in
			var newCtx = ctx
			let content: HTTPRequestContentType
			if let cached = ctx.cachedContent {
				content = cached
			} else {
				content = try await ctx.request.readContent()
				newCtx.cachedContent = content
			}
			return (newCtx, try await call(output, content))
		}
	}
}

// MARK: - statusCheck

public extension Routes {
	func statusCheck(_ handler: @Sendable @escaping (OutType) async throws -> HTTPResponseStatus) -> Routes<InType, OutType> {
		applyFuncs { ctx, output in
			let status = try await handler(output)
			var newCtx = ctx
			newCtx.responseStatus = status
			switch status.code {
			case 200..<300:
				return (newCtx, output)
			default:
				throw TerminationType.criteriaFailed(status)
			}
		}
	}
	func statusCheck(_ handler: @Sendable @escaping () async throws -> HTTPResponseStatus) -> Routes<InType, OutType> {
		statusCheck { _ in try await handler() }
	}
}

// MARK: - decode

public extension Routes {
	func decode<Type: Decodable, NewOut>(_ type: Type.Type,
	                                    _ handler: @Sendable @escaping (OutType, Type) async throws -> NewOut) -> Routes<InType, NewOut> {
		applyFuncs { ctx, output in
			var newCtx = ctx
			let content: HTTPRequestContentType
			if let cached = ctx.cachedContent {
				content = cached
			} else {
				content = try await ctx.request.readContent()
				newCtx.cachedContent = content
			}
			let decoded = try newCtx.request.decode(type, content: content)
			return (newCtx, try await handler(output, decoded))
		}
	}
	func decode<Type: Decodable, NewOut>(_ type: Type.Type,
	                                    _ handler: @Sendable @escaping (Type) async throws -> NewOut) -> Routes<InType, NewOut> {
		decode(type) { try await handler($1) }
	}
	func decode<Type: Decodable>(_ type: Type.Type) -> Routes<InType, Type> {
		decode(type) { $1 }
	}
}

// MARK: - unwrap

public extension Routes {
	func unwrap<U, NewOut>(_ call: @Sendable @escaping (U) async throws -> NewOut) -> Routes<InType, NewOut> where OutType == Optional<U> {
		map {
			guard let unwrapped = $0 else {
				throw ErrorOutput(status: .internalServerError, description: "Assertion failed")
			}
			return try await call(unwrapped)
		}
	}
}

// MARK: - dir (compose parent routes with child routes)

public extension Routes {
	func dir<NewOut>(_ registries: [Routes<OutType, NewOut>]) throws -> Routes<InType, NewOut> {
		var composed: [String: Routes<InType, NewOut>.Handler] = [:]
		var seen = Set<String>()
		var dups: [String] = []

		for (parentPath, parentHandler) in routes {
			for childRoutes in registries {
				for (childPath, childHandler) in childRoutes.routes {
					let (meth, subPath) = childPath.splitMethod
					let newPath: String
					if let meth = meth {
						newPath = meth.name + "://" + parentPath.splitMethod.1.appending(component: subPath)
					} else {
						newPath = parentPath.appending(component: subPath)
					}
					if !seen.insert(newPath).inserted { dups.append(newPath) }
					let p = parentHandler
					let c = childHandler
					composed[newPath] = { ctx, input in
						let (midCtx, midOut) = try await p(ctx, input)
						return try await c(midCtx, midOut)
					}
				}
			}
		}
		guard dups.isEmpty else { throw RouteError.duplicatedRoutes(dups) }
		return .init(composed)
	}

	func dir<NewOut>(_ registry: Routes<OutType, NewOut>, _ rest: Routes<OutType, NewOut>...) throws -> Routes<InType, NewOut> {
		try dir([registry] + rest)
	}

	func dir<NewOut>(@RouteBuilder<OutType, NewOut> makeChildren: (Routes<OutType, OutType>) throws -> [Routes<OutType, NewOut>]) throws -> Routes<InType, NewOut> {
		try dir(makeChildren(root(path: "/", OutType.self)))
	}
	func dir<NewOut>(type: NewOut.Type, @RouteBuilder<OutType, NewOut> makeChildren: (Routes<OutType, OutType>) throws -> [Routes<OutType, NewOut>]) throws -> Routes<InType, NewOut> {
		try dir(makeChildren(root(path: "/", OutType.self)))
	}
	func dir<NewOut>(@RouteBuilder<OutType, NewOut> makeChildren: (Routes<OutType, OutType>) throws -> Routes<OutType, NewOut>) throws -> Routes<InType, NewOut> {
		try dir([makeChildren(root(path: "/", OutType.self))])
	}
	func dir<NewOut>(type: NewOut.Type, @RouteBuilder<OutType, NewOut> makeChildren: (Routes<OutType, OutType>) throws -> Routes<OutType, NewOut>) throws -> Routes<InType, NewOut> {
		try dir([makeChildren(root(path: "/", OutType.self))])
	}
}

// MARK: - top-level dir constructors

public func root<NewOut>(@RouteBuilder<HTTPRequest, NewOut> makeChildren: (Routes<HTTPRequest, HTTPRequest>) throws -> [Routes<HTTPRequest, NewOut>]) throws -> Routes<HTTPRequest, NewOut> {
	try root().dir(makeChildren(root()))
}
public func root<NewOut>(type: NewOut.Type, @RouteBuilder<HTTPRequest, NewOut> makeChildren: (Routes<HTTPRequest, HTTPRequest>) throws -> [Routes<HTTPRequest, NewOut>]) throws -> Routes<HTTPRequest, NewOut> {
	try root().dir(makeChildren(root()))
}
