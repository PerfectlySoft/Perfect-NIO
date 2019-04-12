//
//  ServerRegistry.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2018-11-20.
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
import NIO
import NIOHTTP1
import NIOSSL
import Dispatch

extension SocketAddress: Hashable {
	public func hash(into hasher: inout Hasher) {
		hasher.combine(description.hashValue)
	}
}

struct ServerInfo {
	let address: SocketAddress
	let hostName: String?
	let channel: Channel
	let tls: TLSConfiguration?
	let sslContext: SSLContext?
}

final class MultiPlexHTTPHandler: ChannelInboundHandler {
	public typealias InboundIn = HTTPServerRequestPart
	public typealias OutboundOut = HTTPServerResponsePart
}

fileprivate enum GlobalServerMap {
	static private let serverInfoAccessQueue = DispatchQueue(label: "serverInfoAccess")
	static private var serverMap: [SocketAddress:ServerInfo] = [:]
	static func makeKey(port: Int,
						address: String) -> String {
		return "\(address)"
	}
	static func get(_ key: SocketAddress) -> ServerInfo? {
		return GlobalServerMap.serverInfoAccessQueue.sync { GlobalServerMap.serverMap[key] }
	}
	static func set(_ key: SocketAddress, _ newValue: ServerInfo) {
		GlobalServerMap.serverInfoAccessQueue.sync { GlobalServerMap.serverMap[key] = newValue }
	}
}



//enum ServerRegistry {
//	static func addServer(hostName: String,
//						  address: SocketAddress,
//						  tls: TLSConfiguration?) throws -> EventLoopFuture<Channel> {
//		
//	}
//}
