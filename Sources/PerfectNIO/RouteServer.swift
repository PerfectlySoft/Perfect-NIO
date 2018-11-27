//
//  RouteServer.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-10-24.
//

import NIO
import NIOHTTP1
import NIOOpenSSL
import Foundation

/* TODO
struct requestinfoforlogging {
}
*/
public enum HTTPRequestContentType {
	case none,
		multiPartForm(MimeReader),
		urlForm(QueryDecoder),
		other([UInt8])
}

public protocol HTTPRequest {
	var method: HTTPMethod { get }
	var uri: String { get }
	var headers: HTTPHeaders { get }
	var uriVariables: [String:String] { get set }
	var path: String { get }
	var searchArgs: QueryDecoder? { get }
	var contentType: String? { get }
	var contentLength: Int { get }
	var contentRead: Int { get }
	var contentConsumed: Int { get }
	func readSomeContent() -> EventLoopFuture<[ByteBuffer]>
	func readContent() -> EventLoopFuture<HTTPRequestContentType>
}

public protocol ListeningRoutes {
	@discardableResult
	func stop() -> ListeningRoutes
	func wait() throws
}

public protocol BoundRoutes {
	var port: Int { get }
	var address: String { get }
	func listen() throws -> ListeningRoutes
}

func configureHTTPServerPipeline(pipeline: ChannelPipeline, tls: TLSConfiguration?) -> EventLoopFuture<Void> {
	let responseEncoder = HTTPResponseEncoder()
	let requestDecoder = HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)
	var handlers: [ChannelHandler] = []
	if let configuration = tls {
		let sslContext = try! SSLContext(configuration: configuration)
		let handler = try! OpenSSLServerHandler(context: sslContext)
		handlers.append(handler)
	}
	handlers.append(responseEncoder)
	handlers.append(requestDecoder)
	handlers.append(HTTPServerPipelineHandler())
	
	// FIX: re-enable this with next NIO release
	//handlers.append(HTTPServerProtocolErrorHandler())
	
	// TBD
//	if let (upgraders, completionHandler) = upgrade {
//		let upgrader = HTTPServerUpgradeHandler(upgraders: upgraders,
//												httpEncoder: responseEncoder,
//												extraHTTPHandlers: Array(handlers.dropFirst()),
//												upgradeCompletionHandler: completionHandler)
//		handlers.append(upgrader)
//	}
	return pipeline.addHandlers(handlers, first: false)
}

class NIOBoundRoutes: BoundRoutes {
	typealias RegistryType = Routes<HTTPRequest, HTTPOutput>
	private let childGroup: EventLoopGroup
	let acceptGroup: MultiThreadedEventLoopGroup
	private let channel: Channel
	public let port: Int
	public let address: String
	init(registry: RegistryType,
		 port: Int,
		 address: String,
		 threadGroup: EventLoopGroup?,
		 tls: TLSConfiguration?
		) throws {
		let ag = MultiThreadedEventLoopGroup(numberOfThreads: 1)
		acceptGroup = ag
		childGroup = threadGroup ?? ag
		let finder = try RouteFinderDual(registry)
		self.port = port
		self.address = address
		
		var bs = ServerBootstrap(group: acceptGroup, childGroup: childGroup)
			.serverChannelOption(ChannelOptions.backlog, value: 256)
			.serverChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
			.serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
		if threadGroup == nil {
			bs = bs.serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEPORT), value: 1)
		}
		channel = try bs
			.childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
			.childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
			.childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
			.childChannelOption(ChannelOptions.autoRead, value: true)
			.childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
			.childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator(minimum: 1024, initial: 4096, maximum: 65536))
			.childChannelInitializer {
				channel in
				configureHTTPServerPipeline(pipeline: channel.pipeline, tls: tls)
				.then {
					channel.pipeline.add(handler: NIOHTTPHandler(finder: finder))
				}
			}.bind(host: address, port: port).wait()
	}
	public func listen() throws -> ListeningRoutes {
		return NIOListeningRoutes(channel: channel)
	}
}

class NIOListeningRoutes: ListeningRoutes {
	private let channel: Channel
	private let f: EventLoopFuture<Void>
	private static var globalInitialized: Bool = {
		var sa = sigaction()
	#if os(Linux)
		sa.__sigaction_handler.sa_handler = SIG_IGN
	#else
		sa.__sigaction_u.__sa_handler = SIG_IGN
	#endif
		sa.sa_flags = 0
		sigaction(SIGPIPE, &sa, nil)
		var rlmt = rlimit()
	#if os(Linux)
		getrlimit(Int32(RLIMIT_NOFILE.rawValue), &rlmt)
		rlmt.rlim_cur = rlmt.rlim_max
		setrlimit(Int32(RLIMIT_NOFILE.rawValue), &rlmt)
	#else
		getrlimit(RLIMIT_NOFILE, &rlmt)
		rlmt.rlim_cur = rlim_t(OPEN_MAX)
		setrlimit(RLIMIT_NOFILE, &rlmt)
	#endif
		return true
	}()
	init(channel: Channel) {
		_ = NIOListeningRoutes.globalInitialized
		self.channel = channel
//		channel.read()
		f = channel.closeFuture
	}
	@discardableResult
	public func stop() -> ListeningRoutes {
		channel.close(promise: nil)
		return self
	}
	public func wait() throws {
		try f.wait()
	}
}

public extension Routes where InType == HTTPRequest, OutType == HTTPOutput {
	func bind(port: Int, address: String = "0.0.0.0", tls: TLSConfiguration? = nil) throws -> BoundRoutes {
		return try NIOBoundRoutes(registry: self,
								  port: port,
								  address: address,
								  threadGroup: MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount),
								  tls: tls)
	}
	func bind(count: Int, port: Int, address: String = "0.0.0.0", tls: TLSConfiguration? = nil) throws -> [BoundRoutes] {
		if count == 1 {
			return [try bind(port: port, address: address)]
		}
		return try (0..<count).map { _ in
			return try NIOBoundRoutes(registry: self,
									  port: port,
									  address: address,
									  threadGroup: nil,
									  tls: tls)
		}
	}
}

extension HTTPMethod {
	static var allCases: [HTTPMethod] {
		return [
		.GET,.PUT,.ACL,.HEAD,.POST,.COPY,.LOCK,.MOVE,.BIND,.LINK,.PATCH,
		.TRACE,.MKCOL,.MERGE,.PURGE,.NOTIFY,.SEARCH,.UNLOCK,.REBIND,.UNBIND,
		.REPORT,.DELETE,.UNLINK,.CONNECT,.MSEARCH,.OPTIONS,.PROPFIND,.CHECKOUT,
		.PROPPATCH,.SUBSCRIBE,.MKCALENDAR,.MKACTIVITY,.UNSUBSCRIBE
		]
	}
	var name: String {
		switch self {
		case .GET:
			return "GET"
		case .PUT:
			return "PUT"
		case .ACL:
			return "ACL"
		case .HEAD:
			return "HEAD"
		case .POST:
			return "POST"
		case .COPY:
			return "COPY"
		case .LOCK:
			return "LOCK"
		case .MOVE:
			return "MOVE"
		case .BIND:
			return "BIND"
		case .LINK:
			return "LINK"
		case .PATCH:
			return "PATCH"
		case .TRACE:
			return "TRACE"
		case .MKCOL:
			return "MKCOL"
		case .MERGE:
			return "MERGE"
		case .PURGE:
			return "PURGE"
		case .NOTIFY:
			return "NOTIFY"
		case .SEARCH:
			return "SEARCH"
		case .UNLOCK:
			return "UNLOCK"
		case .REBIND:
			return "REBIND"
		case .UNBIND:
			return "UNBIND"
		case .REPORT:
			return "REPORT"
		case .DELETE:
			return "DELETE"
		case .UNLINK:
			return "UNLINK"
		case .CONNECT:
			return "CONNECT"
		case .MSEARCH:
			return "MSEARCH"
		case .OPTIONS:
			return "OPTIONS"
		case .PROPFIND:
			return "PROPFIND"
		case .CHECKOUT:
			return "CHECKOUT"
		case .PROPPATCH:
			return "PROPPATCH"
		case .SUBSCRIBE:
			return "SUBSCRIBE"
		case .MKCALENDAR:
			return "MKCALENDAR"
		case .MKACTIVITY:
			return "MKACTIVITY"
		case .UNSUBSCRIBE:
			return "UNSUBSCRIBE"
		case .RAW(let value):
			return value
		}
	}
}

extension HTTPMethod: Hashable {
	public var hashValue: Int { return name.hashValue }
}

extension String {
	var method: HTTPMethod {
		switch self {
		case "GET":
			return .GET
		case "PUT":
			return .PUT
		case "ACL":
			return .ACL
		case "HEAD":
			return .HEAD
		case "POST":
			return .POST
		case "COPY":
			return .COPY
		case "LOCK":
			return .LOCK
		case "MOVE":
			return .MOVE
		case "BIND":
			return .BIND
		case "LINK":
			return .LINK
		case "PATCH":
			return .PATCH
		case "TRACE":
			return .TRACE
		case "MKCOL":
			return .MKCOL
		case "MERGE":
			return .MERGE
		case "PURGE":
			return .PURGE
		case "NOTIFY":
			return .NOTIFY
		case "SEARCH":
			return .SEARCH
		case "UNLOCK":
			return .UNLOCK
		case "REBIND":
			return .REBIND
		case "UNBIND":
			return .UNBIND
		case "REPORT":
			return .REPORT
		case "DELETE":
			return .DELETE
		case "UNLINK":
			return .UNLINK
		case "CONNECT":
			return .CONNECT
		case "MSEARCH":
			return .MSEARCH
		case "OPTIONS":
			return .OPTIONS
		case "PROPFIND":
			return .PROPFIND
		case "CHECKOUT":
			return .CHECKOUT
		case "PROPPATCH":
			return .PROPPATCH
		case "SUBSCRIBE":
			return .SUBSCRIBE
		case "MKCALENDAR":
			return .MKCALENDAR
		case "MKACTIVITY":
			return .MKACTIVITY
		case "UNSUBSCRIBE":
			return .UNSUBSCRIBE
		default:
			return .RAW(value: self)
		}
	}
	var splitMethod: (HTTPMethod?, String) {
		if let i = range(of: "://") {
			return (String(self[self.startIndex..<i.lowerBound]).method, String(self[i.upperBound...]))
		}
		return (nil, self)
	}
}

public extension Routes {
	var GET: Routes<InType, OutType> { return method(.GET) }
	var POST: Routes { return method(.POST) }
	var PUT: Routes { return method(.PUT) }
	var DELETE: Routes { return method(.DELETE) }
	var OPTIONS: Routes { return method(.OPTIONS) }
	func method(_ method: HTTPMethod, _ methods: HTTPMethod...) -> Routes {
		let methods = [method] + methods
		return .init(.init(routes:
			registry.routes.flatMap {
				route in
				return methods.map {
					($0.name + "://" + route.0.splitMethod.1, route.1)
				}
			}
		))
	}
}
