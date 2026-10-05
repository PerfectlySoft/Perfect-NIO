//
//  MimeReaderTests.swift
//  PerfectNIOSmokeTests
//
//  MimeReader upload handling: temp file mode and directory, and what happens when
//  a file part can't be stored. The file-size-limit cases run as exit tests for the
//  same reason as in TempUploadFileTests: RLIMIT_FSIZE and SIGXFSZ are process-wide.
//

import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import NIOHTTP1
@testable import PerfectNIO

private let boundary = "----PerfectNIOMimeBoundary"
private let multipartContentType = "multipart/form-data; boundary=\(boundary)"

/// A body with a text field `title` and a file part `upload` holding `payload`.
private func multipartBody(payload: [UInt8]) -> [UInt8] {
    var body: [UInt8] = []
    body += Array("--\(boundary)\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhello\r\n".utf8)
    body += Array("--\(boundary)\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"blob.bin\"\r\n".utf8)
    body += Array("Content-Type: application/octet-stream\r\n\r\n".utf8)
    body += payload
    body += Array("\r\n--\(boundary)--\r\n".utf8)
    return body
}

private let payload: [UInt8] = (0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 13) }

/// A fresh, empty directory (with a trailing "/") for one test's temp files.
private func makeScratchDirectory() throws -> String {
    let dir = NSTemporaryDirectory() + "perfect-nio-mime-\(UUID().uuidString)/"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
    return dir
}

private func filesIn(_ dir: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
}

private func permissions(of path: String) -> Int? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return Int(st.st_mode) & 0o777
}

private func limitFileSize(to bytes: UInt64) {
    signal(SIGXFSZ, SIG_IGN)
    var lim = rlimit()
    #if canImport(Glibc)
    let resource = __rlimit_resource_t(RLIMIT_FSIZE.rawValue)
    #else
    let resource = RLIMIT_FSIZE
    #endif
    getrlimit(resource, &lim)
    lim.rlim_cur = rlim_t(bytes)
    guard setrlimit(resource, &lim) == 0 else { exit(90) }
}

private func status(_ output: ErrorOutput) -> HTTPResponseStatus? {
    let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/")
    return output.head(request: HTTPRequestInfo(head: head, options: []))?.status
}

private struct UploadForm: Decodable {
    let title: String
    let upload: FileUpload
}

/// Posts `body` as multipart/form-data to `/` on `port`.
private func postMultipart(port: Int, body: [UInt8]) async throws -> (Data, Int) {
    var request = URLRequest(url: URL(string: "http://localhost:\(port)/")!)
    request.httpMethod = "POST"
    request.setValue(multipartContentType, forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(body)
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    return (data, (response as! HTTPURLResponse).statusCode)
}

/// Decodes the upload and replies "<fileSize> <mode in octal>" for its temp file.
private func uploadRoutes() -> Routes<HTTPRequest, HTTPOutput> {
    root().POST.decode(UploadForm.self) { form -> String in
        let mode = permissions(of: form.upload.tmpFileName).map { String($0, radix: 8) } ?? "missing"
        return "\(form.upload.fileSize) \(mode)"
    }.text()
}

@Suite("MimeReader uploads")
struct MimeReaderTests {

    /// Finished uploads keep mkstemp's 0600. On main they were chmod'ed to 0666, so any
    /// local user could rewrite the file before the handler read it.
    @Test func uploadIsOwnerOnly() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let reader = MimeReader(multipartContentType, tempDir: dir)
        reader.addToBuffer(bytes: multipartBody(payload: payload))
        #expect(reader.error == nil)
        let upload = try #require(reader.bodySpecs.first { $0.fieldName == "upload" })
        #expect(upload.fileSize == payload.count)
        #expect(permissions(of: upload.tmpFileName) == 0o600)
    }

    /// The default temp directory is NSTemporaryDirectory() (per-user on Darwin,
    /// TMPDIR-aware on Linux), not a hard-coded "/tmp/".
    @Test func defaultTempDirectory() throws {
        let expected = NSTemporaryDirectory().hasSuffix("/") ? NSTemporaryDirectory() : NSTemporaryDirectory() + "/"
        #expect(MimeReader.defaultTempDirectory == expected)
        let reader = MimeReader(multipartContentType)
        #expect(reader.tempDirectory == expected)
        reader.addToBuffer(bytes: multipartBody(payload: [1, 2, 3]))
        let upload = try #require(reader.bodySpecs.first { $0.fieldName == "upload" })
        #expect(upload.tmpFileName.hasPrefix(expected + kPerfectTempPrefix))
    }

    /// If the temp file can't be created, parsing stops with the real errno and the
    /// request fails with 500. On main, mkstemp's failure went unnoticed and every
    /// write threw EBADF, which was logged and dropped.
    @Test func unwritableTempDirectoryFailsTheRequest() throws {
        let missing = NSTemporaryDirectory() + "perfect-nio-missing-\(UUID().uuidString)/"
        let reader = MimeReader(multipartContentType, tempDir: missing)
        reader.addToBuffer(bytes: multipartBody(payload: payload))
        #expect((reader.error as? POSIXError)?.code == .ENOENT)
        let upload = try #require(reader.bodySpecs.first { $0.fieldName == "upload" })
        #expect(upload.file == nil)
        #expect(upload.tmpFileName == "")
        #expect(upload.fileSize == 0)

        let error = #expect(throws: ErrorOutput.self) {
            _ = try MimeReader.parse(contentType: multipartContentType, body: multipartBody(payload: payload), tempDir: missing)
        }
        #expect(error.flatMap(status) == .internalServerError)
    }

    /// A body cut off before its closing boundary is rejected with 400 rather than
    /// handing on the last part truncated, and the partial file is deleted. On main the
    /// 100-byte prefix reached the handler as a complete upload.
    @Test(arguments: ["", "\r", "\r\n--\(boundary)\r\n"])
    func incompleteBodyIsRejected(tail: String) throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var body = multipartBody(payload: payload)
        body = Array(body[..<(body.count - payload.count - "\r\n--\(boundary)--\r\n".utf8.count + 100)])
        body += Array(tail.utf8)
        let error = #expect(throws: ErrorOutput.self) {
            _ = try MimeReader.parse(contentType: multipartContentType, body: body, tempDir: dir)
        }
        #expect(error.flatMap(status) == .badRequest)
        #expect(filesIn(dir).isEmpty)
    }

    /// A body that ends right after the closing "--boundary--" (no final CRLF) is complete.
    @Test func closingBoundaryWithoutTrailingCRLFIsComplete() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let body = Array(multipartBody(payload: payload).dropLast(2))
        let reader = try MimeReader.parse(contentType: multipartContentType, body: body, tempDir: dir)
        #expect(reader.bodySpecs.first { $0.fieldName == "upload" }?.fileSize == payload.count)
    }

    /// `decode` refuses a reader whose upload failed, for HTTPRequest implementations
    /// that build `.multiPartForm` themselves rather than through `readContent()`.
    @Test func decodeRejectsAFailedReader() throws {
        let missing = NSTemporaryDirectory() + "perfect-nio-missing-\(UUID().uuidString)/"
        let reader = MimeReader(multipartContentType, tempDir: missing)
        reader.addToBuffer(bytes: multipartBody(payload: payload))
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/",
                                   headers: ["Content-Type": multipartContentType])
        let request = NIOAsyncHTTPRequest(head: head, body: [], channel: nil, isTLS: false)
        #expect(throws: ErrorOutput.self) {
            _ = try request.decode(UploadForm.self, content: .multiPartForm(reader))
        }
    }

    /// Control for the server exit test: without a file size limit the same request
    /// succeeds, and the handler sees the whole file with mode 0600.
    @Test func serverAcceptsUpload() async throws {
        try await Server(routes: uploadRoutes(), port: 0).withServer { port in
            let (data, status) = try await postMultipart(port: port, body: multipartBody(payload: payload))
            #expect(status == 200)
            #expect(String(decoding: data, as: UTF8.self) == "\(payload.count) 600")
        }
    }

    /// End to end: a body cut off mid-file gets 400. On main the handler ran and
    /// replied 200 with the 100-byte prefix as the whole upload.
    @Test func serverRejectsIncompleteBody() async throws {
        var body = multipartBody(payload: payload)
        body = Array(body[..<(body.count - payload.count - "\r\n--\(boundary)--\r\n".utf8.count + 100)])
        try await Server(routes: uploadRoutes(), port: 0).withServer { port in
            let (_, status) = try await postMultipart(port: port, body: body)
            #expect(status == 400)
        }
    }

    #if !SWT_NO_EXIT_TESTS
    /// A write that hits the file size limit (EFBIG) stops parsing, deletes the partial
    /// file and ignores further input. On main the error was logged, the reader went
    /// quiet and the partial file was left in bodySpecs with an undercounted fileSize.
    /// A field part after the file checks that input after the failure is ignored.
    /// Exit codes: 2 = no error, 3 = wrong error, 4 = file left behind, 5 = spec not
    /// cleared, 6 = parse didn't throw 413, 7 = parsing continued after the failure.
    @Test func fileSizeLimitStopsParsingAndDeletesThePartialFile() async {
        await #expect(processExitsWith: .exitCode(0)) {
            let dir = NSTemporaryDirectory() + "perfect-nio-mime-\(UUID().uuidString)/"
            guard (try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)) != nil else { exit(91) }
            limitFileSize(to: 1024)
            var body = multipartBody(payload: payload)
            body.removeLast("--\r\n".utf8.count)
            body += Array("\r\nContent-Disposition: form-data; name=\"after\"\r\n\r\nx\r\n--\(boundary)--\r\n".utf8)
            let reader = MimeReader(multipartContentType, tempDir: dir)
            // Two chunks, so input arrives after the failure too.
            reader.addToBuffer(bytes: Array(body[..<(body.count / 2)]))
            reader.addToBuffer(bytes: Array(body[(body.count / 2)...]))
            let parse = Result { try MimeReader.parse(contentType: multipartContentType, body: body, tempDir: dir) }
            let leftovers = filesIn(dir)
            try? FileManager.default.removeItem(atPath: dir)
            guard let error = reader.error else { exit(2) }
            guard (error as? POSIXError)?.code == .EFBIG else { exit(3) }
            guard leftovers.isEmpty else { exit(4) }
            guard let upload = reader.bodySpecs.first(where: { $0.fieldName == "upload" }),
                  upload.file == nil, upload.fileSize == 0, upload.tmpFileName == "" else { exit(5) }
            guard case .failure(let e) = parse, (e as? ErrorOutput).flatMap(status) == .payloadTooLarge else { exit(6) }
            guard reader.bodySpecs.count == 2 else { exit(7) }
            exit(0)
        }
    }

    /// End to end: an upload that exceeds the file size limit gets 413 instead of
    /// reaching the handler. On main the handler ran and the response was 200, with a
    /// FileUpload whose fileSize was 0 and whose file held the first 1024 of 4096 bytes.
    /// Exit codes: 2 = 200 (handler ran), 3 = other status, 4 = request failed.
    @Test func serverRejectsUploadOverTheFileSizeLimit() async {
        await #expect(processExitsWith: .exitCode(0)) {
            limitFileSize(to: 1024)
            let status: Int32
            do {
                status = try await Server(routes: uploadRoutes(), port: 0).withServer { port in
                    let (_, code) = try await postMultipart(port: port, body: multipartBody(payload: payload))
                    return code == 413 ? 0 : code == 200 ? 2 : 3
                }
            } catch {
                status = 4
            }
            exit(status)
        }
    }
    #endif
}
