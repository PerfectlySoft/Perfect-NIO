//
//  RequestDecoder.swift
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
import NIOHTTP1
import PerfectLib
import PerfectMIME
import struct Foundation.UUID

public struct FileUpload: Codable {
	public let contentType: MIMEType
	public let fileName: String
	public let fileSize: Int
	public let tmpFileName: String
}

enum RequestParamValue {
	case string(String), file(FileUpload)
}

typealias RequestTuples = (String, RequestParamValue)

/// Extensions on HTTPRequest which permit the request body to be decoded to a Codable type.
public extension HTTPRequest {
	/// Decode the request body into the desired type, or throw an error.
	func decode<A: Decodable>(_ type: A.Type, content: HTTPRequestContentType) throws -> A {
		let postTuples: [RequestTuples]
		switch content {
		case .none:
			postTuples = []
		case .multiPartForm(let mime):
			postTuples = mime.bodySpecs.filter {
				spec in
				// prune empty file uploads
				if nil == spec.file,
					spec.fileName == "",
					spec.contentType == "application/octet-stream" {
					return false
				}
				return true
			}.map {
				spec in
				let value: RequestParamValue
				if spec.file != nil {
					value = .file(FileUpload(contentType: MIMEType(spec.contentType),
										 fileName: spec.fileName,
										 fileSize: spec.fileSize,
										 tmpFileName: spec.tmpFileName))
				} else {
					value = .string(spec.fieldValue)
				}
				return (spec.fieldName, value)
			}
		case .urlForm(let t):
			postTuples = t.map {($0.0, .string($0.1))}
		case .other(let body):
			return try JSONDecoder().decode(A.self, from: Data(body))
		}
		return try A.init(from:
			RequestDecoder(params:
				uriVariables.map {($0.key, .string($0.value))}
					+ (searchArgs?.map {($0.0, .string($0.1))} ?? []) + postTuples))
	}
}

private enum SpecialType {
	case uint8Array, int8Array, data, uuid, date
	init?(_ type: Any.Type) {
		switch type {
		case is [Int8].Type:
			self = .int8Array
		case is [UInt8].Type:
			self = .uint8Array
		case is Data.Type:
			self = .data
		case is UUID.Type:
			self = .uuid
		case is Date.Type:
			self = .date
		default:
			return nil
		}
	}
}

class RequestReader<K : CodingKey>: KeyedDecodingContainerProtocol {
	typealias Key = K
	var codingPath: [CodingKey] = []
	var allKeys: [Key] = []
	let parent: RequestDecoder
	let params: [RequestTuples]
	init(_ p: RequestDecoder, params: [RequestTuples]) {
		parent = p
		self.params = params
	}
	func getValue<T: LosslessStringConvertible>(_ key: Key) throws -> T {
		let str: RequestParamValue
		let keyStr = key.stringValue
		if let v = params.first(where: {$0.0 == keyStr}) {
			str = v.1
		} else {
			throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Key \(keyStr) not found."))
		}
		let finalStr: String
		switch str {
		case .string(let string):
			finalStr = string
		case .file(let file):
			finalStr = "\(file.tmpFileName);\(file.contentType);\(file.fileName);\(file.fileSize)"
		}
		guard let ret = T.init(finalStr) else {
			throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Could not convert to \(T.self).")
		}
		return ret
	}
	func contains(_ key: Key) -> Bool {
		return nil != params.first(where: {$0.0 == key.stringValue})
	}
	func decodeNil(forKey key: Key) throws -> Bool {
		return !contains(key)
	}
	func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
		return try getValue(key)
	}
	func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
		return try getValue(key)
	}
	func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
		return try getValue(key)
	}
	func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
		return try getValue(key)
	}
	func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
		return try getValue(key)
	}
	func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
		return try getValue(key)
	}
	func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
		return try getValue(key)
	}
	func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
		return try getValue(key)
	}
	func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
		return try getValue(key)
	}
	func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
		return try getValue(key)
	}
	func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
		return try getValue(key)
	}
	func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
		return try getValue(key)
	}
	func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
		return try getValue(key)
	}
	func decode(_ type: String.Type, forKey key: Key) throws -> String {
		return try getValue(key)
	}
	func decode<T>(_ t: T.Type, forKey key: Key) throws -> T where T : Decodable {
		if let special = SpecialType(t) {
			switch special {
			case .uint8Array, .int8Array, .data:
				throw DecodingError.keyNotFound(key, .init(codingPath: codingPath,
														   debugDescription: "The data type \(t) is not supported for GET requests."))
			case .uuid:
				let str: String = try getValue(key)
				guard let uuid = UUID(uuidString: str) else {
					throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Could not convert to \(t).")
				}
				return uuid as! T
			case .date:
				// !FIX! need to support better formats
				let str: String = try getValue(key)
				guard let date = Date(fromISO8601: str) else {
					throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Could not convert to \(t).")
				}
				return date as! T
			}
		} else if t == FileUpload.self {
			let keyStr = key.stringValue
			if let v = params.first(where: {$0.0 == keyStr}),
				case .file(let f) = v.1 {
				return f as! T
			}
		}
		throw DecodingError.keyNotFound(key, .init(codingPath: codingPath,
												   debugDescription: "The data type \(t) is not supported for GET requests."))
	}
	func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> where NestedKey : CodingKey {
		fatalError("Unimplimented")
	}
	func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
		fatalError("Unimplimented")
	}
	func superDecoder() throws -> Decoder {
		fatalError("Unimplimented")
	}
	func superDecoder(forKey key: Key) throws -> Decoder {
		fatalError("Unimplimented")
	}
}

class RequestUnkeyedReader: UnkeyedDecodingContainer, SingleValueDecodingContainer {
	let codingPath: [CodingKey] = []
	var count: Int? = 1
	var isAtEnd: Bool { return currentIndex != 0 }
	var currentIndex: Int = 0
	let parent: RequestDecoder
	var decodedType: Any.Type?
	var typeDecoder: RequestDecoder?
	init(parent p: RequestDecoder) {
		parent = p
	}
	func advance(_ t: Any.Type) {
		currentIndex += 1
		decodedType = t
	}
	func decodeNil() -> Bool {
		return false
	}
	func decode(_ type: Bool.Type) throws -> Bool {
		advance(type)
		return false
	}
	func decode(_ type: Int.Type) throws -> Int {
		advance(type)
		return 0
	}
	func decode(_ type: Int8.Type) throws -> Int8 {
		advance(type)
		return 0
	}
	func decode(_ type: Int16.Type) throws -> Int16 {
		advance(type)
		return 0
	}
	func decode(_ type: Int32.Type) throws -> Int32 {
		advance(type)
		return 0
	}
	func decode(_ type: Int64.Type) throws -> Int64 {
		advance(type)
		return 0
	}
	func decode(_ type: UInt.Type) throws -> UInt {
		advance(type)
		return 0
	}
	func decode(_ type: UInt8.Type) throws -> UInt8 {
		advance(type)
		return 0
	}
	func decode(_ type: UInt16.Type) throws -> UInt16 {
		advance(type)
		return 0
	}
	func decode(_ type: UInt32.Type) throws -> UInt32 {
		advance(type)
		return 0
	}
	func decode(_ type: UInt64.Type) throws -> UInt64 {
		advance(type)
		return 0
	}
	func decode(_ type: Float.Type) throws -> Float {
		advance(type)
		return 0
	}
	func decode(_ type: Double.Type) throws -> Double {
		advance(type)
		return 0
	}
	func decode(_ type: String.Type) throws -> String {
		advance(type)
		return ""
	}
	func decode<T: Decodable>(_ type: T.Type) throws -> T {
		advance(type)
		return try T(from: parent)
	}
	func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> where NestedKey : CodingKey {
		fatalError("Unimplimented")
	}
	func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
		fatalError("Unimplimented")
	}
	func superDecoder() throws -> Decoder {
		currentIndex += 1
		return parent
	}
}

class RequestDecoder: Decoder {
	var codingPath: [CodingKey] = []
	var userInfo: [CodingUserInfoKey : Any] = [:]
	let params: [RequestTuples]
	init(params: [RequestTuples]) {
		self.params = params
	}
	func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key : CodingKey {
		return KeyedDecodingContainer<Key>(RequestReader<Key>(self, params: params))
	}
	func unkeyedContainer() throws -> UnkeyedDecodingContainer {
		return RequestUnkeyedReader(parent: self)
	}
	func singleValueContainer() throws -> SingleValueDecodingContainer {
		return RequestUnkeyedReader(parent: self)
	}
}

