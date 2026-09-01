//
//  RouteContext.swift
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

import Foundation
import NIOHTTP1

/// Per-request state carried through the async route pipeline.
/// Replaces the legacy HandlerState + RouteValueBox pair.
public struct RouteContext: @unchecked Sendable {
    // The underlying HTTP request — a reference type owned by a single connection task.
    // @unchecked Sendable: the request (NIOAsyncHTTPRequest) buffers its body up front and
    // is not shared across connection tasks.
    let request: any HTTPRequest
    public var responseStatus: HTTPResponseStatus = .ok
    public var responseHeaders: HTTPHeaders = .init()
    public internal(set) var uriVariables: [String: String] = [:]

    private let uriComponents: [String]
    private var componentIndex: Int = 0
    var cachedContent: HTTPRequestContentType?

    init(request: any HTTPRequest, uri: String) {
        self.request = request
        uriComponents = uri.cleanedPath.components
    }

    var currentComponent: String? {
        guard componentIndex < uriComponents.count else { return nil }
        return uriComponents[componentIndex]
    }

    // Returns remaining path from current position, without leading slash.
    var trailingComponents: String {
        guard componentIndex < uriComponents.count else { return "" }
        return uriComponents[componentIndex...].joined(separator: "/")
    }

    mutating func advanceComponent() {
        guard componentIndex < uriComponents.count else { return }
        componentIndex += 1
    }

    var responseHead: HTTPHead {
        HTTPHead(status: responseStatus, headers: responseHeaders)
    }
}
