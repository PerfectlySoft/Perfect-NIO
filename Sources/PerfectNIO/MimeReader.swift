//
//  MimeReader.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 7/6/15.
//	Copyright (C) 2015 PerfectlySoft, Inc.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2016 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Logging

private let logger = Logger(label: "perfect.nio.mimereader")

enum MimeReadState {
	case stateNone
	case stateBoundary // next thing to be read will be a boundry
	case stateHeader // read header lines until data starts
	case stateFieldValue // read a simple value; name has already been set
	case stateFile // read file data until boundry
	case stateDone
	case stateError // a file part couldn't be stored; see `MimeReader.error`
}

let kMultiPartForm = "multipart/form-data"
let kBoundary = "boundary"

let kContentDisposition = "Content-Disposition"
let kContentType = "Content-Type"

let kPerfectTempPrefix = "perfect_upload_"

let mime_cr: UInt8 = 13
let mime_lf: UInt8 = 10
let mime_dash: UInt8 = 45

/// This class is responsible for reading multi-part POST form data, including handling file uploads.
/// Data can be given for parsing in little bits at a time by calling the `addTobuffer` function.
/// Any file uploads which are encountered will be written to the temporary directory indicated when the `MimeReader` is created.
/// Temporary files are created with mode 0600 and deleted when this object is deinitialized.
///
/// If a file part can't be stored (for example the disk is full or the file size limit
/// is reached), parsing stops and `error` is set. The temporary file for that part is
/// deleted. Callers that feed data with `addToBuffer` must check `error` before using
/// `bodySpecs`; the server's `readContent()` turns it into an error response.
///
/// Under an RLIMIT_FSIZE, writing past the limit raises SIGXFSZ, which terminates the process
/// unless it's ignored. `Server` ignores it when it starts (unless the app has set its own
/// disposition); code that uses `MimeReader` without a `Server` must do that itself to get EFBIG.
public final class MimeReader {
	
	/// The default directory for temporary upload files: `NSTemporaryDirectory()`,
	/// which honors `TMPDIR` and on Darwin is a per-user directory.
	public static var defaultTempDirectory: String {
		let dir = NSTemporaryDirectory()
		return dir.hasSuffix("/") ? dir : dir + "/"
	}
	
	/// Array of BodySpecs representing each part that was parsed.
	public var bodySpecs = [BodySpec]()
	
	/// The error which stopped parsing, if a file part couldn't be stored.
	/// When this is set, `bodySpecs` is incomplete and must not be treated as the request's content.
	public private(set) var error: (any Error)?
	
	var (multi, gotFile) = (false, false)
	var buffer = [UInt8]()
	let tempDirectory: String
	var state: MimeReadState = .stateNone
	
	/// The boundary identifier.
	public var boundary = ""
	
	/// This class represents a single part of a multi-part POST submission
	public class BodySpec {
		/// The name of the form field.
		public var fieldName = ""
		/// The value for the form field.
		/// Having a fieldValue and a file are mutually exclusive.
		public var fieldValue = ""
		var fieldValueTempBytes: [UInt8]?
		/// The content-type for the form part.
		public var contentType = ""
		/// The client-side file name as submitted by the form.
		public var fileName = ""
		/// The size of the file which was submitted.
		public var fileSize = 0
		/// The name of the temporary file which stores the file upload on the server-side.
		public var tmpFileName = ""
		/// The temporary file for the local upload.
		public var file: TempUploadFile?
		
		init() {
			
		}
		
		/// Clean up the BodySpec, possibly closing and deleting any associated temporary file.
		public func cleanup() {
			if let f = file {
				if f.exists {
					f.delete()
				}
				file = nil
			}
		}
		
		deinit {
			cleanup()
		}
	}
	
	/// Initialize given a Content-type header line.
	/// - parameter contentType: The Content-type header line.
	/// - parameter tempDir: The path, ending in "/", of the directory in which to store temporary files.
	///   Defaults to `MimeReader.defaultTempDirectory`.
	public init(_ contentType: String, tempDir: String = MimeReader.defaultTempDirectory) {
		tempDirectory = tempDir
		if contentType.hasPrefix(kMultiPartForm) {
			multi = true
			if let range = contentType.range(of: kBoundary) {
				
				let startIndex = contentType.index(range.lowerBound, offsetBy: kBoundary.count+1)
				let endIndex = contentType.endIndex
				
				let boundaryString = String(contentType[startIndex..<endIndex])
				boundary.append("--")
				boundary.append(boundaryString)
				state = .stateBoundary
			}
		}
	}
	
	/// Returns false, having called `fail`, if the file couldn't be created.
	func openTempFile(spec spc: BodySpec) -> Bool {
		let file = TempUploadFile(withPrefix: tempDirectory + kPerfectTempPrefix)
		if let openError = file.openError {
			fail(openError, spec: spc, while: "creating a temp file in \(tempDirectory)")
			return false
		}
		spc.file = file
		spc.tmpFileName = file.path
		return true
	}
	
	/// Stops parsing and deletes the part's temporary file, so a partly written upload
	/// is never handed on as if it were complete.
	func fail(_ err: any Error, spec: BodySpec, while action: String = "writing file upload data") {
		logger.error("upload failed \(action): \(err)")
		error = err
		state = .stateError
		spec.cleanup()
		spec.tmpFileName = ""
		spec.fileSize = 0
	}
	
	/// Parses a complete multipart body, throwing an `ErrorOutput` if a file part couldn't be
	/// stored, or 400 if the body ends before its closing boundary (the last part would
	/// otherwise be handed on truncated).
	static func parse(contentType: String, body: [UInt8], tempDir: String = MimeReader.defaultTempDirectory) throws -> MimeReader {
		let reader = MimeReader(contentType, tempDir: tempDir)
		reader.addToBuffer(bytes: body)
		try reader.throwIfFailed()
		guard reader.state == .stateDone else {
			reader.bodySpecs.forEach { $0.cleanup() }
			throw ErrorOutput(status: .badRequest, description: "Incomplete multipart body.")
		}
		return reader
	}
	
	/// Throws an `ErrorOutput` for `error`, if set: 413 if the file size limit was reached
	/// (EFBIG), 507 if the disk or quota is full, otherwise 500.
	func throwIfFailed() throws {
		guard let error else { return }
		switch (error as? POSIXError)?.code {
		case .EFBIG?:
			throw ErrorOutput(status: .payloadTooLarge, description: "Uploaded file is too large.")
		case .ENOSPC?, .EDQUOT?:
			throw ErrorOutput(status: .insufficientStorage, description: "Could not store uploaded file.")
		default:
			throw ErrorOutput(status: .internalServerError, description: "Could not store uploaded file.")
		}
	}
	
	func isBoundaryStart(bytes byts: [UInt8], start: Array<UInt8>.Index) -> Bool {
		var gen = boundary.utf8.makeIterator()
		var pos = start
		var next = gen.next()
		while let char = next {
			
			if pos == byts.endIndex || char != byts[pos] {
				return false
			}
			
			pos += 1
			next = gen.next()
		}
		return next == nil // got to the end is success
	}
	
	func isField(name nam: String, bytes: [UInt8], start: Array<UInt8>.Index) -> Array<UInt8>.Index {
		var check = start
		let end = bytes.endIndex
		var gen = nam.utf8.makeIterator()
		while check != end {
			if bytes[check] == 58 { // :
				return check
			}
			let gened = gen.next()
			
			if gened == nil {
				break
			}
			
			if tolower(Int32(gened!)) != tolower(Int32(bytes[check])) {
				break
			}
			
			check = check.advanced(by: 1)
		}
		return end
	}
	
	func pullValue(name nam: String, from: String) -> String {
		var accum = ""
		let option = String.CompareOptions.caseInsensitive
		if let nameRange = from.range(of: nam + "=", options: option) {
			var start = nameRange.upperBound
			let end = from.endIndex
			
			if from[start] == "\"" {
				start = from.index(after: start)
			}
			
			while start < end {
				if from[start] == "\"" || from[start] == ";" {
					break;
				}
				accum.append(from[start])
				start = from.index(after: start)
			}
		}
		return accum
	}
	
	@discardableResult
	func internalAddToBuffer(bytes byts: [UInt8]) -> MimeReadState {
		
		var clearBuffer = true
		var position = byts.startIndex
		let end = byts.endIndex
		
		while position != end {
			switch state {
			case .stateDone, .stateNone:
				return .stateNone
			case .stateError:
				buffer.removeAll()
				return .stateError
			case .stateBoundary:
				if position.distance(to: end) < boundary.count + 2 {
					buffer = Array(byts[position..<end])
					clearBuffer = false
					position = end
				} else {
					position = position.advanced(by: boundary.count)
					if byts[position] == mime_dash && byts[position.advanced(by: 1)] == mime_dash {
						state = .stateDone
						position = position.advanced(by: 2)
					} else {
						state = .stateHeader
						bodySpecs.append(BodySpec())
					}
					if state != .stateDone {
						position = position.advanced(by: 2) // line end
					} else {
						position = end
					}
				}
			case .stateHeader:
				var eolPos = position
				while eolPos.distance(to: end) > 1 {
					let b1 = byts[eolPos]
					let b2 = byts[eolPos.advanced(by: 1)]
					if b1 == mime_cr && b2 == mime_lf {
						break
					}
					eolPos = eolPos.advanced(by: 1)
				}
				if eolPos.distance(to: end) <= 1 { // no eol
					buffer = Array(byts[position..<end])
					clearBuffer = false
					position = end
				} else {
					let spec = bodySpecs.last!
					if eolPos != position {
						let check = isField(name: kContentDisposition, bytes: byts, start: position)
						if check != end { // yes, content-disposition
							let lineRange = Array(byts[check.advanced(by: 2)..<eolPos])
							let line = String(bytes: lineRange, encoding: .utf8) ?? ""
							let name = pullValue(name: "name", from: line)
							let fileName = pullValue(name: "filename", from: line)
							spec.fieldName = name
							spec.fileName = fileName
						} else {
							let check = isField(name: kContentType, bytes: byts, start: position)
							if check != end { // yes, content-type
								let lineRange = Array(byts[check.advanced(by: 2)..<eolPos])
								let line = String(bytes: lineRange, encoding: .utf8) ?? ""
								spec.contentType = line
								
							}
						}
						position = eolPos.advanced(by: 2)
					}
					if (eolPos == position || position != end) && position.distance(to: end) > 1 && byts[position] == mime_cr && byts[position.advanced(by: 1)] == mime_lf {
						position = position.advanced(by: 2)
						if spec.fileName.count > 0 {
							if openTempFile(spec: spec) {
								state = .stateFile
							}
						} else {
							state = .stateFieldValue
							spec.fieldValueTempBytes = [UInt8]()
						}
					}
				}
			case .stateFieldValue:
				let spec = bodySpecs.last!
				while position != end {
					if byts[position] == mime_cr {
						if position.distance(to: end) == 1 {
							buffer = Array(byts[position..<end])
							clearBuffer = false
							position = end
							continue
						}
						if byts[position.advanced(by: 1)] == mime_lf {
							if isBoundaryStart(bytes: byts, start: position.advanced(by: 2)) {
								position = position.advanced(by: 2)
								state = .stateBoundary
								let bytes = spec.fieldValueTempBytes ?? []
								let line = String(bytes: bytes, encoding: .utf8) ?? ""
								spec.fieldValue = line
								spec.fieldValueTempBytes = nil
								break
							} else if position.distance(to: end) - 2 < boundary.count {
								// we are at the eol, but check to see if the next line may be starting a boundary
								if position.distance(to: end) < 4 || (byts[position.advanced(by: 2)] == mime_dash && byts[position.advanced(by: 3)] == mime_dash) {
									buffer = Array(byts[position..<end])
									clearBuffer = false
									position = end
									continue
								}
							}
							
						}
					}
					spec.fieldValueTempBytes!.append(byts[position])
					position = position.advanced(by: 1)
				}
			case .stateFile:
				let spec = bodySpecs.last!
				guard let file = spec.file else {
					fail(POSIXError(.EBADF), spec: spec)
					break
				}
				while position != end {
					if byts[position] == mime_cr {
						if position.distance(to: end) == 1 {
							buffer = Array(byts[position..<end])
							clearBuffer = false
							position = end
							continue
						}
						if byts[position.advanced(by: 1)] == mime_lf {
							if isBoundaryStart(bytes: byts, start: position.advanced(by: 2)) {
								position = position.advanced(by: 2)
								state = .stateBoundary
								// end of file data. The file keeps mkstemp's 0600 mode.
								file.close()
								break
							} else if position.distance(to: end) - 2 < boundary.count {
								// we are at the eol, but check to see if the next line may be starting a boundary
								if position.distance(to: end) < 4 || (byts[position.advanced(by: 2)] == mime_dash && byts[position.advanced(by: 3)] == mime_dash) {
									buffer = Array(byts[position..<end])
									clearBuffer = false
									position = end
									continue
								}
							}
						}
					}
					// write as much data as we reasonably can
					var writeEnd = position
					byts.withUnsafeBufferPointer { qPtr in
						while writeEnd < end {
							if qPtr[writeEnd] == mime_cr {
								if end - writeEnd < 2 {
									break
								}
								if qPtr[writeEnd + 1] == mime_lf {
									if isBoundaryStart(bytes: byts, start: writeEnd + 2) {
										break
									} else if end - writeEnd - 2 < boundary.count {
										// we are at the eol, but check to see if the next line may be starting a boundary
										if end - writeEnd < 4 || (qPtr[writeEnd + 2] == mime_dash && qPtr[writeEnd + 3] == mime_dash) {
											break
										}
									}
								}
							}
							writeEnd += 1
						}
					}
					do {
						let length = writeEnd - position
						spec.fileSize += try file.write(bytes: byts, dataPosition: position, length: length)
					} catch let e {
						fail(e, spec: spec)
						break
					}
					if (writeEnd == end) {
						buffer.removeAll()
					}
					position = writeEnd
					gotFile = true
				}
			}
		}
		if clearBuffer {
			buffer.removeAll()
		}
		return state
	}
	
	/// Add data to be parsed.
	/// - parameter bytes: The array of UInt8 to be parsed.
	public func addToBuffer(bytes byts: [UInt8]) {
		if isMultiPart {
			
			if self.buffer.count != 0 {
				self.buffer.append(contentsOf: byts)
				internalAddToBuffer(bytes: self.buffer)
			} else {
				internalAddToBuffer(bytes: byts)
			}
		} else {
			self.buffer.append(contentsOf: byts)
		}
	}
	
	/// Add data to be parsed.
	/// - parameter bytes: The array of UInt8 to be parsed.
	public func addToBuffer(bytes byts: UnsafePointer<UInt8>, length: Int) {
		if isMultiPart {
			if self.buffer.count != 0 {
				for i in 0..<length {
					self.buffer.append(byts[i])
				}
				internalAddToBuffer(bytes: self.buffer)
			} else {
				var a = [UInt8]()
				for i in 0..<length {
					a.append(byts[i])
				}
				internalAddToBuffer(bytes: a)
			}
		} else {
			for i in 0..<length {
				self.buffer.append(byts[i])
			}
		}
	}
	
	/// Returns true of the content type indicated a multi-part form.
	public var isMultiPart: Bool {
		return self.multi
	}
}
