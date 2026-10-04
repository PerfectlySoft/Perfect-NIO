//
//  TempUploadFileTests.swift
//  PerfectNIOSmokeTests
//
//  TempUploadFile.write: range validation, empty input, short writes and errno.
//  Swift Testing rather than XCTest so the RLIMIT_FSIZE cases can run as exit
//  tests: the limit and SIGXFSZ disposition are process-wide, so they're set in
//  a child process instead of the shared test runner.
//

import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import PerfectNIO

private func makeTempFile() -> TempUploadFile {
    TempUploadFile(withPrefix: NSTemporaryDirectory() + "perfect-nio-tempfile-test-")
}

private func contents(of file: TempUploadFile) -> [UInt8] {
    FileManager.default.contents(atPath: file.path).map { [UInt8]($0) } ?? []
}

private func posixCode(_ error: any Error) -> POSIXErrorCode? {
    (error as? POSIXError)?.code
}

/// Caps the size of files this process may write (soft limit only, so it can be
/// raised again) and ignores SIGXFSZ, so exceeding the cap makes write(2) fail with
/// EFBIG instead of killing the process. Only call this inside an exit test.
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

private func unlimitFileSize() {
    var lim = rlimit()
    #if canImport(Glibc)
    let resource = __rlimit_resource_t(RLIMIT_FSIZE.rawValue)
    #else
    let resource = RLIMIT_FSIZE
    #endif
    getrlimit(resource, &lim)
    lim.rlim_cur = lim.rlim_max
    setrlimit(resource, &lim)
}

@Suite("TempUploadFile.write")
struct TempUploadFileTests {

    @Test func writesTheRequestedRange() throws {
        let file = makeTempFile()
        defer { file.delete() }
        let bytes: [UInt8] = Array(0..<100)
        #expect(try file.write(bytes: bytes, dataPosition: 10, length: 30) == 30)
        #expect(try file.write(bytes: bytes, dataPosition: 90, length: 10) == 10)
        file.close()
        #expect(contents(of: file) == Array(bytes[10..<40]) + Array(bytes[90..<100]))
    }

    @Test func writesLargeBuffersCompletely() throws {
        let file = makeTempFile()
        defer { file.delete() }
        let bytes = (0..<(8 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        #expect(try file.write(bytes: bytes, dataPosition: 1, length: bytes.count - 1) == bytes.count - 1)
        file.close()
        #expect(contents(of: file) == Array(bytes[1...]))
    }

    /// On main these either over-read the array (and return as if they'd succeeded)
    /// or reach write(2) and come back as EIO.
    @Test(arguments: [
        (3, 1),             // starts past the end
        (2, 5),             // runs past the end
        (0, 4),             // one byte too long
        (-1, 1),            // negative position
        (0, -1),            // negative length
        (1, Int.max),       // position + length overflows
        (Int.max, 1),
    ])
    func rejectsRangesOutsideTheArray(dataPosition: Int, length: Int) throws {
        let file = makeTempFile()
        defer { file.delete() }
        let error = #expect(throws: POSIXError.self) {
            try file.write(bytes: [1, 2, 3], dataPosition: dataPosition, length: length)
        }
        #expect(error?.code == .EINVAL)
        file.close()
        #expect(contents(of: file).isEmpty)
    }

    @Test func emptyRangesWriteNothing() throws {
        let file = makeTempFile()
        defer { file.delete() }
        #expect(try file.write(bytes: [], dataPosition: 0, length: 0) == 0)
        #expect(try file.write(bytes: [1, 2, 3], dataPosition: 3, length: 0) == 0)
        #expect(try file.write(bytes: [1, 2, 3], dataPosition: 1, length: 0) == 0)
        file.close()
        #expect(contents(of: file).isEmpty)
    }

    @Test func emptyArrayWithNonZeroLengthIsRejected() throws {
        let file = makeTempFile()
        defer { file.delete() }
        let error = #expect(throws: POSIXError.self) {
            try file.write(bytes: [], dataPosition: 0, length: 1)
        }
        #expect(error?.code == .EINVAL)
    }

    @Test func writingAfterCloseThrowsEBADF() throws {
        let file = makeTempFile()
        defer { file.delete() }
        file.close()
        let error = #expect(throws: POSIXError.self) {
            try file.write(bytes: [1], dataPosition: 0, length: 1)
        }
        #expect(error?.code == .EBADF)
    }

    /// End to end through MimeReader, the internal caller: a file part whose bytes
    /// include CRLFs and dashes arrives intact whether the body comes in one piece
    /// or in small chunks that split lines and boundaries.
    @Test(arguments: [Int.max, 7, 1])
    func multipartUploadRoundTrips(chunkSize: Int) throws {
        let boundary = "----PerfectNIOTestBoundary"
        var payload: [UInt8] = Array("line one\r\n--not a boundary\r\n-".utf8)
        payload += (0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        payload += Array("\r\n\r\n--".utf8)
        var body: [UInt8] = []
        body += Array("--\(boundary)\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhello\r\n".utf8)
        body += Array("--\(boundary)\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"blob.bin\"\r\n".utf8)
        body += Array("Content-Type: application/octet-stream\r\n\r\n".utf8)
        body += payload
        body += Array("\r\n--\(boundary)--\r\n".utf8)

        let reader = MimeReader("multipart/form-data; boundary=\(boundary)", tempDir: NSTemporaryDirectory())
        var offset = 0
        while offset < body.count {
            let end = offset + min(chunkSize, body.count - offset)
            reader.addToBuffer(bytes: Array(body[offset..<end]))
            offset = end
        }
        defer { reader.bodySpecs.forEach { $0.cleanup() } }

        let field = try #require(reader.bodySpecs.first { $0.fieldName == "title" })
        #expect(field.fieldValue == "hello")
        let upload = try #require(reader.bodySpecs.first { $0.fieldName == "upload" })
        #expect(upload.fileName == "blob.bin")
        #expect(upload.fileSize == payload.count)
        let written = FileManager.default.contents(atPath: upload.tmpFileName).map { [UInt8]($0) }
        #expect(written == payload)
    }

    #if !SWT_NO_EXIT_TESTS
    /// write(2) fails outright with EFBIG when the file can't grow at all. On main
    /// this came back as EIO. Exit codes: 2 = didn't throw, 3 = wrong error.
    @Test func reportsTheRealErrno() async {
        await #expect(processExitsWith: .exitCode(0)) {
            let file = TempUploadFile(withPrefix: NSTemporaryDirectory() + "perfect-nio-tempfile-test-")
            limitFileSize(to: 0)
            let result = Result { try file.write(bytes: [1, 2, 3, 4], dataPosition: 0, length: 4) }
            unlimitFileSize()
            let status: Int32 = switch result {
            case .success: 2
            case .failure(let e): posixCode(e) == .EFBIG ? 0 : 3
            }
            file.delete()
            exit(status)
        }
    }

    /// With a 10-byte file-size limit, write(2) of 20 bytes writes 10 and returns 10
    /// (a short write); retrying then fails with EFBIG. On main the short count was
    /// returned as success, so the caller silently lost the last 10 bytes.
    /// Exit codes: 2 = returned without throwing, 3 = wrong error, 4 = file contents.
    @Test func shortWritesAreRetriedThenReported() async {
        await #expect(processExitsWith: .exitCode(0)) {
            let file = TempUploadFile(withPrefix: NSTemporaryDirectory() + "perfect-nio-tempfile-test-")
            let bytes: [UInt8] = Array(1...20)
            limitFileSize(to: 10)
            let result = Result { try file.write(bytes: bytes, dataPosition: 0, length: 20) }
            unlimitFileSize()
            file.close()
            let status: Int32 = switch result {
            case .success: 2
            case .failure(let e) where posixCode(e) != .EFBIG: 3
            case .failure: contents(of: file) == Array(bytes[0..<10]) ? 0 : 4
            }
            file.delete()
            exit(status)
        }
    }

    /// Control for the short-write test: a write that exactly fits the limit succeeds
    /// in full, so the EFBIG there comes from the limit and not from the setup.
    /// Exit codes: 2 = threw, 3 = wrong count, 4 = contents.
    @Test func writesUpToTheLimitSucceed() async {
        await #expect(processExitsWith: .exitCode(0)) {
            let file = TempUploadFile(withPrefix: NSTemporaryDirectory() + "perfect-nio-tempfile-test-")
            let bytes: [UInt8] = Array(1...20)
            limitFileSize(to: 20)
            let result = Result { try file.write(bytes: bytes, dataPosition: 0, length: 20) }
            unlimitFileSize()
            file.close()
            let status: Int32 = switch result {
            case .failure: 2
            case .success(let n) where n != 20: 3
            case .success: contents(of: file) == bytes ? 0 : 4
            }
            file.delete()
            exit(status)
        }
    }
    #endif
}
