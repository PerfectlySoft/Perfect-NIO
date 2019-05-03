//
//  RouteDescription.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2019-05-02.
//

import Foundation

extension Routes: CustomStringConvertible {
	public var description: String {
		return registry.routes.keys.joined(separator: "\n")
	}
}

public struct RouteDescription {
	let uri: String
}

extension RouteDescription: CustomStringConvertible {
	public var description: String {
		return uri
	}
}

public extension Routes where InType == HTTPRequest, OutType == HTTPOutput {
	var describe: [RouteDescription] {
		return registry.routes.map {
			RouteDescription(uri: $0.key)
		}
	}
}
