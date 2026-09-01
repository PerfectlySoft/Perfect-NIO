//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2026 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// ModelInfo — sanitized schema descriptor for an ORM-backed model, surfaced
// in the admin console so an operator can see what tables/columns a
// PerfectCRUD-backed (or any other ORM-backed) host actually has, without
// PerfectAdminConsole depending on PerfectCRUD itself.
//
// Same shape as Phase 3's DatasourceInfo: PerfectAdminConsole stays
// framework-agnostic and dependency-light -- the host converts its own
// reflected schema (e.g. PerfectCRUD's TableStructure, from
// SomeModel.CRUDTableStructure()) into ModelInfo when implementing
// registeredModels(). No row data lives here; this is schema only.

import Foundation

/// One column in a model's schema, as reported to the admin console.
public struct ModelColumnInfo: Sendable {
    public let name: String
    /// Human-readable type label -- e.g. "String", "Int", "Date". Free-form;
    /// the admin console only displays it, never parses it.
    public let typeName: String
    public let isPrimaryKey: Bool
    public let isOptional: Bool

    public init(name: String, typeName: String, isPrimaryKey: Bool = false, isOptional: Bool = false) {
        self.name = name
        self.typeName = typeName
        self.isPrimaryKey = isPrimaryKey
        self.isOptional = isOptional
    }
}

/// Sanitized schema descriptor for one model/table.
///
/// **No row data.** Return only what's safe to display to an operator who
/// has already authenticated to the admin console -- table name and column
/// shape, not the data inside it.
public struct ModelInfo: Sendable {
    /// Unique key identifying this model -- typically the table name.
    /// Stable and lowercase-kebab-ish is recommended but not required.
    public let name: String
    /// Human-readable label, if different from `name` (e.g. a friendlier
    /// display name). Falls back to `name` when not provided.
    public let label: String
    public let columns: [ModelColumnInfo]

    public init(name: String, label: String? = nil, columns: [ModelColumnInfo]) {
        self.name = name
        self.label = label ?? name
        self.columns = columns
    }
}
