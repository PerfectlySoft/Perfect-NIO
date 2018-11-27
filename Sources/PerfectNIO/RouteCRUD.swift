//
//  RouteCRUD.swift
//  HTTPCRUDLib
//
//  Created by Kyle Jessup on 2018-10-28.
//

import Foundation
import PerfectCRUD
import Dispatch
import NIO

public typealias DCP = DatabaseConfigurationProtocol

let foreignEventsQueue = DispatchQueue(label: "foreignEventsQueue")//, attributes: .concurrent)

public extension Routes {
	func db<C: DCP, NewOut>(_ provide: @autoclosure @escaping () throws -> Database<C>,
					_ call: @escaping (OutType, Database<C>) throws -> NewOut) -> Routes<InType, NewOut> {
		return self.async {
			i, promise in
			do {
				let db = try provide()
				promise.succeed(result: try call(i, db))
			} catch {
				promise.fail(error: error)
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
				promise.succeed(result: try call(i, table))
			} catch {
				promise.fail(error: error)
			}
		}
	}
}
