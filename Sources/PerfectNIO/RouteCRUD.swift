//
//  RouteCRUD.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2018-10-28.
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
import PerfectCRUD
import Dispatch
import NIO

public typealias DCP = DatabaseConfigurationProtocol

let foreignEventsQueue = DispatchQueue(label: "foreignEventsQueue", attributes: .concurrent)

public extension Routes {
	func db<C: DCP, NewOut>(_ provide: @autoclosure @escaping () throws -> Database<C>,
					_ call: @escaping (OutType, Database<C>) throws -> NewOut) -> Routes<InType, NewOut> {
		return self.async {
			i, promise in
			do {
				let db = try provide()
				promise.succeed(try call(i, db))
			} catch {
				promise.fail(error)
			}
		}
	}
	func table<C: DCP, T: Codable, NewOut>(_ provide: @autoclosure @escaping () throws -> Database<C>,
										   _ type: T.Type,
										   _ call: @escaping (OutType, Table<T, Database<C>>) throws -> NewOut) -> Routes<InType, NewOut> {
		return self.async {
			i, promise in
			do {
				let table = try provide().table(type)
				promise.succeed(try call(i, table))
			} catch {
				promise.fail(error)
			}
		}
	}
}
