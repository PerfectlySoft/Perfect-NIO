//
//  RouteDescription.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2019-05-02.
//

import Foundation

extension Routes: CustomStringConvertible {
	public var description: String {
		routes.keys.sorted().joined(separator: "\n")
	}
}

public struct RouteDescription {
	let uri: String
}

extension RouteDescription: CustomStringConvertible {
	public var description: String { uri }
}

public extension Routes where InType == HTTPRequest, OutType == HTTPOutput {
	var describe: [RouteDescription] {
		routes.map { RouteDescription(uri: $0.key) }
	}
}
