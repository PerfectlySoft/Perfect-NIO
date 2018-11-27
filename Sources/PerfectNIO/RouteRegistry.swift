//
//  RouteRegistry.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-10-23.
//

import NIO
import NIOHTTP1

/// An error occurring during process of building a set of routes.
public enum RouteError: Error, CustomStringConvertible {
	case duplicatedRoutes([String])
	public var description: String {
		switch self {
		case .duplicatedRoutes(let r):
			return "Duplicated routes: \(r.joined(separator: ", "))"
		}
	}
}

// Internal structure of a route set.
// This is exposed to users only through struct `Routes`.
struct RouteRegistry<InType, OutType>: CustomStringConvertible {
	typealias ResolveFunc = (InType) throws -> OutType
	typealias Tuple = (String,ResolveFunc)
	let routes: [String:ResolveFunc]
	public var description: String {
		return routes.keys.sorted().joined(separator: "\n")
	}
	init(_ routes: [String:ResolveFunc]) {
		self.routes = routes
	}
	init(checkedRoutes routes: [Tuple]) throws {
		var check = Set<String>()
		try routes.forEach {
			let key = $0.0
			guard !check.contains(key) else {
				throw RouteError.duplicatedRoutes([key])
			}
			check.insert(key)
		}
		self.init(Dictionary(uniqueKeysWithValues: routes))
	}
	init(routes: [Tuple]) {
		self.init(Dictionary(uniqueKeysWithValues: routes))
	}
	func append<NewOut>(_ registry: RouteRegistry<OutType, NewOut>) -> RouteRegistry<InType, NewOut> {
		let a = routes.flatMap {
			(t: Tuple) -> [RouteRegistry<InType, NewOut>.Tuple] in
			let (itemPath, itemFnc) = t
			return registry.routes.map {
				(t: RouteRegistry<OutType, NewOut>.Tuple) -> RouteRegistry<InType, NewOut>.Tuple in
				let (subPath, subFnc) = t
				let (meth, path) = subPath.splitMethod
				let newPath = nil == meth ?
					itemPath.appending(component: path) :
					meth!.name + "://" + itemPath.splitMethod.1.appending(component: path)
				return (newPath, { try subFnc(itemFnc($0)) })
			}
		}
		return .init(routes: a)
	}
	func validate() throws {
		let paths = routes.map { $0.0 }.sorted()
		var dups = Set<String>()
		var last: String?
		paths.forEach {
			s in
			if s == last {
				dups.insert(s)
			}
			last = s
		}
		guard dups.isEmpty else {
			throw RouteError.duplicatedRoutes(Array(dups))
		}
	}
}

// The value used in all route Futures.
struct RouteValueBox<ValueType> {
	let state: HandlerState
	let value: ValueType
	init(_ state: HandlerState, _ value: ValueType) {
		self.state = state
		self.value = value
	}
}

typealias Future = EventLoopFuture

/// Main routes object.
/// Created by calling `root()` or by chaining a function from an existing route.
@dynamicMemberLookup
public struct Routes<InType, OutType> {
	typealias Registry = RouteRegistry<Future<RouteValueBox<InType>>, Future<RouteValueBox<OutType>>>
	let registry: Registry
	init(_ registry: Registry) {
		self.registry = registry
	}
	func applyPaths(_ call: (String) -> String) -> Routes {
		return .init(.init(routes: registry.routes.map { (call($0.key), $0.value) }))
	}
	func applyFuncs<NewOut>(_ call: @escaping (Future<RouteValueBox<OutType>>) -> Future<RouteValueBox<NewOut>>) -> Routes<InType, NewOut> {
		return .init(.init(routes: registry.routes.map {
			let (path, fnc) = $0
			return (path, { call(try fnc($0)) })
		}))
	}
	func apply<NewOut>(paths: (String) -> String, funcs call: @escaping (Future<RouteValueBox<OutType>>) -> Future<RouteValueBox<NewOut>>) -> Routes<InType, NewOut> {
		return .init(.init(routes: registry.routes.map {
			let (path, fnc) = $0
			return (paths(path), { call(try fnc($0)) })
		}))
	}
}

/// Create a root route accepting/returning the HTTPRequest.
public func root() -> Routes<HTTPRequest, HTTPRequest> {
	return .init(.init(["/":{$0}]))
}

/// Create a root route accepting the HTTPRequest and returning some new value.
public func root<NewOut>(_ call: @escaping (HTTPRequest) throws -> NewOut) -> Routes<HTTPRequest, NewOut> {
	return .init(.init(["/":{$0.thenThrowing{RouteValueBox($0.state, try call($0.value))}}]))
}

/// Create a root route returning some new value.
public func root<NewOut>(_ call: @escaping () throws -> NewOut) -> Routes<HTTPRequest, NewOut> {
	return .init(.init(["/":{$0.thenThrowing{RouteValueBox($0.state, try call())}}]))
}

/// Create a root route accepting and returning some new value.
public func root<NewOut>(path: String = "/", _ type: NewOut.Type) -> Routes<NewOut, NewOut> {
	return .init(.init([path:{$0}]))
}

public extension Routes {
	/// Add a function mapping the input to the output.
	func map<NewOut>(_ call: @escaping (OutType) throws -> NewOut) -> Routes<InType, NewOut> {
		return applyFuncs {
			return $0.thenThrowing {
				return RouteValueBox($0.state, try call($0.value))
			}
		}
	}
	/// Add a function mapping the input to the output.
	func map<NewOut>(_ call: @escaping () throws -> NewOut) -> Routes<InType, NewOut> {
		return applyFuncs {
			return $0.thenThrowing {
				return RouteValueBox($0.state, try call())
			}
		}
	}
}
public extension Routes where OutType: Collection {
	/// Map the values of a Collection to a new Array.
	func map<NewOut>(_ call: @escaping (OutType.Element) throws -> NewOut) -> Routes<InType, Array<NewOut>>{
		return applyFuncs {
			return $0.thenThrowing {
				return RouteValueBox($0.state, try $0.value.map(call))
			}
		}
	}
}

public extension Routes {
	/// Create and return a new route path.
	/// The new route accepts and returns the same types as the existing set.
	/// This adds an additional path component to the route set.
	subscript(dynamicMember name: String) -> Routes {
		return path(name)
	}
	/// Create and return a new route path.
	/// The new route accepts the input value and returns a new value.
	/// This adds an additional path component to the route set.
	subscript<NewOut>(dynamicMember name: String) -> (@escaping (OutType) throws -> NewOut) -> Routes<InType, NewOut> {
		return {self.path(name, $0)}
	}
	/// Create and return a new route path.
	/// The new route accepts nothing and returns a new value.
	/// This adds an additional path component to the route set.
	subscript<NewOut>(dynamicMember name: String) -> (@escaping () throws -> NewOut) -> Routes<InType, NewOut> {
		return { call in self.path(name, { _ in return try call()})}
	}
}

public extension Routes {
	/// Create and return a new route path.
	/// The new route accepts and returns the same types as the existing set.
	/// This adds an additional path component to the route set.
	func path(_ name: String) -> Routes {
		return apply(
			paths: {$0.appending(component: name)},
			funcs: {
				$0.thenThrowing {
					$0.state.advanceComponent()
					return $0
				}
			}
		)
	}
	/// Create and return a new route path.
	/// The new route accepts the input value and returns a new value.
	/// This adds an additional path component to the route set.
	func path<NewOut>(_ name: String, _ call: @escaping (OutType) throws -> NewOut) -> Routes<InType, NewOut> {
		return apply(
			paths: {$0.appending(component: name)},
			funcs: {
				$0.thenThrowing {
					$0.state.advanceComponent()
					return RouteValueBox($0.state, try call($0.value))
				}
			}
		)
	}
	/// Create and return a new route path.
	/// The new route accepts nothing and returns a new value.
	/// This adds an additional path component to the route set.
	func path<NewOut>(_ name: String, _ call: @escaping () throws -> NewOut) -> Routes<InType, NewOut> {
		return apply(
			paths: {$0.appending(component: name)},
			funcs: {
				$0.thenThrowing {
					$0.state.advanceComponent()
					return RouteValueBox($0.state, try call())
				}
			}
		)
	}
}

public extension Routes {
	/// Adds the indicated file extension to the route set.
	func ext(_ ext: String) -> Routes {
		let ext = ext.ext
		return applyPaths { $0 + ext }
	}
	/// Adds the indicated file extension to the route set.
	/// The given function accepts the input value and returns a new value.
	func ext<NewOut>(_ ext: String,
					  contentType: String? = nil,
					  _ call: @escaping (OutType) throws -> NewOut) -> Routes<InType, NewOut> {
		let ext = ext.ext
		return apply(
			paths: {$0 + ext},
			funcs: {
				$0.thenThrowing {
					if let c = contentType {
						$0.state.response.addHeader(name: "content-type", value: c)
					}
					return RouteValueBox($0.state, try call($0.value))
				}
			}
		)
	}
}

public extension Routes {
	/// Adds a wild-card path component to the route set.
	/// The given function accepts the input value and the value for that wild-card path component, as given by the HTTP client,
	/// and returns a new value.
	func wild<NewOut>(_ call: @escaping (OutType, String) throws -> NewOut) -> Routes<InType, NewOut> {
		return apply(
			paths: {$0.appending(component: "*")},
			funcs: {
				$0.thenThrowing {
					let c = $0.state.currentComponent ?? "-error-"
					$0.state.advanceComponent()
					return RouteValueBox($0.state, try call($0.value, c))
				}
			}
		)
	}
	/// Adds a wild-card path component to the route set.
	/// Gives the wild-card path component a variable name and the path component value is added as a request urlVariable.
	func wild(name: String) -> Routes {
		return apply(
			paths: {$0.appending(component: "*")},
			funcs: {
				$0.thenThrowing {
					$0.state.request.uriVariables[name] = $0.state.currentComponent ?? "-error-"
					$0.state.advanceComponent()
					return $0
				}
			}
		)
	}
	/// Adds a trailing-wild-card to the route set.
	/// The given function accepts the input value and the value for the remaining path components, as given by the HTTP client,
	/// and returns a new value.
	func trailing<NewOut>(_ call: @escaping (OutType, String) throws -> NewOut) -> Routes<InType, NewOut> {
		return apply(
			paths: {$0.appending(component: "**")},
			funcs: {
				$0.thenThrowing {
					let c = $0.state.trailingComponents ?? "-error-"
					$0.state.advanceComponent()
					return RouteValueBox($0.state, try call($0.value, c))
				}
			}
		)
	}
}

public extension Routes {
	/// Adds the current HTTPRequest as a parameter to the function.
	func request<NewOut>(_ call: @escaping (OutType, HTTPRequest) throws -> NewOut) -> Routes<InType, NewOut> {
		return applyFuncs {
			$0.thenThrowing {
				return RouteValueBox($0.state, try call($0.value, $0.state.request))
			}
		}
	}
	/// Reads the client content body and delivers it to the provided function.
	func readBody<NewOut>(_ call: @escaping (OutType, HTTPRequestContentType) throws -> NewOut) -> Routes<InType, NewOut> {
		return applyFuncs {
			$0.then {
				box in
				return box.state.request.readContent().thenThrowing {
					return RouteValueBox(box.state, try call(box.value, $0))
				}
			}
		}
	}
	/// The caller can inspect the given input value and choose to return an HTTP error code.
	/// If any code outside of 200..<300 is return the request is aborted.
	func statusCheck(_ handler: @escaping (OutType) throws -> HTTPResponseStatus) -> Routes<InType, OutType> {
		return applyFuncs {
			$0.thenThrowing {
				box in
				let status = try handler(box.value)
				box.state.response.status = status
				switch status.code {
				case 200..<300:
					return box
				default:
					throw TerminationType.criteriaFailed
				}
			}
		}
	}
	/// The caller can choose to return an HTTP error code.
	/// If any code outside of 200..<300 is return the request is aborted.
	func statusCheck(_ handler: @escaping () throws -> HTTPResponseStatus) -> Routes<InType, OutType> {
		return statusCheck { _ in try handler() }
	}
	/// Read the client content body and then attempt to decode it as the indicated `Decodable` type.
	/// Both the original input value and the newly decoded object are delivered to the provided function.
	func decode<Type: Decodable, NewOut>(_ type: Type.Type,
										 _ handler: @escaping (OutType, Type) throws -> NewOut) -> Routes<InType, NewOut> {
		return readBody { ($0, $1) }.request {
			return try handler($0.0, try $1.decode(Type.self, content: $0.1))
		}
	}
	/// Read the client content body and then attempt to decode it as the indicated `Decodable` type.
	/// The newly decoded object is delivered to the provided function.
	func decode<Type: Decodable, NewOut>(_ type: Type.Type,
										 _ handler: @escaping (Type) throws -> NewOut) -> Routes<InType, NewOut> {
		return decode(type) { try handler($1) }
	}
	/// Read the client content body and then attempt to decode it as the indicated `Decodable` type.
	/// The newly decoded object becomes the route set's new output value.
	func decode<Type: Decodable>(_ type: Type.Type) -> Routes<InType, Type> {
		return decode(type) { $1 }
	}
}

/// These extensions append new route sets to an existing set.
public extension Routes {
	/// Append new routes to the set given a new output type and a function which receives a route object and returns an array of new routes.
	/// This permits a sort of shorthand for adding new routes.
	/// At times, Swift's type inference can fail to discern what the programmer intends when calling functions like this.
	/// Calling the second version of this method, the one accepting a `type: NewOut.Type` as the first parameter,
	/// can often clarify your intentions to the compiler. If you experience a compilation error with this function, try the other.
	func dir<NewOut>(_ call: (Routes<OutType, OutType>) throws -> [Routes<OutType, NewOut>]) throws -> Routes<InType, NewOut> {
		return try dir(call(root(OutType.self)))
	}
	/// Append new routes to the set given a new output type and a function which receives a route object and returns an array of new routes.
	/// This permits a sort of shorthand for adding new routes.
	/// The first `type` argument to this function serves to help type inference.
	func dir<NewOut>(type: NewOut.Type, _ call: (Routes<OutType, OutType>) -> [Routes<OutType, NewOut>]) throws -> Routes<InType, NewOut> {
		return try dir(call(root(OutType.self)))
	}
	/// Append new routes to this set given an array.
	func dir<NewOut>(_ registries: [Routes<OutType, NewOut>]) throws -> Routes<InType, NewOut> {
		let reg = try RouteRegistry(checkedRoutes: registries.flatMap { $0.registry.routes })
		return .init(registry.append(reg))
	}
	/// Append a new route set to this set.
	func dir<NewOut>(_ registry: Routes<OutType, NewOut>, _ registries: Routes<OutType, NewOut>...) throws -> Routes<InType, NewOut> {
		return try dir([registry] + registries)
	}
}

public extension Routes {
	/// If the output type is an `Optional`, this function permits it to be safely unwraped.
	/// If it can not be unwrapped the request is terminated.
	/// The provided function is called with the unwrapped value.
	func unwrap<U, NewOut>(_ call: @escaping (U) throws -> NewOut) -> Routes<InType, NewOut> where OutType == Optional<U> {
		return map {
			guard let unwrapped = $0 else {
				throw TerminationType.criteriaFailed
			}
			return try call(unwrapped)
		}
	}
}
