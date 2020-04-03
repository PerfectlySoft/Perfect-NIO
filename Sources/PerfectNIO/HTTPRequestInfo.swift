//
//  HTTPRequestInfo.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2019-01-25.
//

import Foundation
import NIOHTTP1

public struct HTTPRequestOptions: OptionSet {
	public typealias RawValue = UInt8
	public let rawValue: RawValue
	public init(rawValue: RawValue) {
		self.rawValue = rawValue
	}
	public static let isTLS = HTTPRequestOptions(rawValue: 1<<0)
	public static let mayCompress = HTTPRequestOptions(rawValue: 1<<1)
}

public struct HTTPRequestInfo {
	public let head: HTTPRequestHead
	public let options: HTTPRequestOptions
	public init(head: HTTPRequestHead, options: HTTPRequestOptions) {
		self.head = head
		self.options = options
	}
}
