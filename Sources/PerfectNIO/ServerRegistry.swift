//
//  ServerRegistry.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-11-20.
//

import Foundation
import NIO
import NIOHTTP1
import NIOOpenSSL
import class NIOOpenSSL.SSLContext
import Dispatch

extension SocketAddress: Hashable {
	public var hashValue: Int {
		return description.hashValue
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
