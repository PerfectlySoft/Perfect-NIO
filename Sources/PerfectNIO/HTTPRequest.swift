//
//  HTTPRequest.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2019-02-11.
//

import NIO
import NIOHTTP1
import Foundation

/// Client content which has been read and parsed (if needed).
public enum HTTPRequestContentType {
	/// There was no content provided by the client.
	case none
	/// A multi-part form/file upload.
	case multiPartForm(MimeReader)
	/// A url-encoded form.
	case urlForm(QueryDecoder)
	/// Some other sort of content.
	case other([UInt8])
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
	var localAddress: SocketAddress? { get }
	var remoteAddress: SocketAddress? { get }
	func readSomeContent() -> EventLoopFuture<[ByteBuffer]>
	func readContent() -> EventLoopFuture<HTTPRequestContentType>
}
