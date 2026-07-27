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
import NIO
import PerfectNIO

public typealias DCP = DatabaseConfigurationProtocol

public extension Routes {
    func db<C: DCP & Sendable, NewOut>(
        _ provide: @autoclosure @escaping @Sendable () throws -> Database<C>,
        _ call: @Sendable @escaping (OutType, Database<C>) async throws -> NewOut
    ) -> Routes<InType, NewOut> {
        map { input in
            let db = try provide()
            return try await call(input, db)
        }
    }

    func table<C: DCP & Sendable, T: Codable & Sendable, NewOut>(
        _ provide: @autoclosure @escaping @Sendable () throws -> Database<C>,
        _ type: T.Type,
        _ call: @Sendable @escaping (OutType, Table<T, Database<C>>) async throws -> NewOut
    ) -> Routes<InType, NewOut> {
        map { input in
            let table = try provide().table(type)
            return try await call(input, table)
        }
    }

    // MARK: - Pooled variants (ADR-0001 Phase 1)
    //
    // Distinguished from the overloads above by the `pool:` label, so
    // existing `.db(makeDB(), ...)` / `.table(makeDB(), Post.self, ...)`
    // call sites keep resolving to the `@autoclosure` overloads unchanged --
    // zero source breaks. New adopters build one `DatabaseConnectionPool` at
    // server startup and switch call sites to `.db(pool: dbPool) { ... }`.

    // Uses `pool.acquire()`/`pool.release(_:)`, not `pool.withConnection(_:)`:
    // `withConnection`'s body closure crosses the `DatabaseConnectionPool`
    // actor boundary as an `@Sendable` closure, which would require
    // `OutType`/`NewOut: Sendable` -- but `OutType` here is commonly
    // `HTTPRequest`, a non-`Sendable` protocol existential, when pooling is
    // wired directly onto `root()`. Acquiring/releasing the connection
    // (`C`, already `Sendable`) and running `call` in this method's own
    // async context instead avoids that constraint entirely.
    func db<C: DCP & Sendable, NewOut>(
        pool: DatabaseConnectionPool<C>,
        _ call: @Sendable @escaping (OutType, Database<C>) async throws -> NewOut
    ) -> Routes<InType, NewOut> {
        map { input in
            let connection = try await pool.acquire()
            do {
                let result = try await call(input, Database(configuration: connection))
                await pool.release(connection)
                return result
            } catch {
                await pool.release(connection)
                throw error
            }
        }
    }

    func table<C: DCP & Sendable, T: Codable & Sendable, NewOut>(
        pool: DatabaseConnectionPool<C>,
        _ type: T.Type,
        _ call: @Sendable @escaping (OutType, Table<T, Database<C>>) async throws -> NewOut
    ) -> Routes<InType, NewOut> {
        map { input in
            let connection = try await pool.acquire()
            do {
                let result = try await call(input, Database(configuration: connection).table(type))
                await pool.release(connection)
                return result
            } catch {
                await pool.release(connection)
                throw error
            }
        }
    }
}
