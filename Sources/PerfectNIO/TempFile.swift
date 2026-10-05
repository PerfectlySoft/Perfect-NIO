import Foundation
#if canImport(Darwin)
import Darwin
private func posixWrite(_ fd: Int32, _ buf: UnsafeRawPointer!, _ n: Int) -> Int { Darwin.write(fd, buf, n) }
private func posixClose(_ fd: Int32) { _ = Darwin.close(fd) }
#else
import Glibc
private func posixWrite(_ fd: Int32, _ buf: UnsafeRawPointer!, _ n: Int) -> Int { Glibc.write(fd, buf, n) }
private func posixClose(_ fd: Int32) { _ = Glibc.close(fd) }
#endif

public final class TempUploadFile {
    public let path: String
    private var fd: Int32
    /// Why `mkstemp` failed, if it did; `path` is then empty and writes throw `EBADF`.
    let openError: POSIXError?

    public var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public init(withPrefix prefix: String) {
        let template = prefix + "XXXXXX"
        let capacity = template.utf8.count + 1
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buf.deallocate() }
        template.withCString { src in _ = memcpy(buf, src, capacity) }
        let result = mkstemp(buf)
        let code = errno
        fd = result
        path = fd >= 0 ? String(cString: buf) : ""
        openError = fd >= 0 ? nil : POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// Writes `bytes[dataPosition..<dataPosition + length]` to the file.
    ///
    /// Retries short writes and `EINTR` until the whole range is written, so on
    /// success the return value is always `length`. Throws `EINVAL` if the range
    /// is not within `bytes`, `EBADF` if the file is closed, and otherwise the
    /// `errno` reported by `write(2)`. If it throws after a short write, the bytes
    /// before the failure are already in the file.
    @discardableResult
    public func write(bytes: [UInt8], dataPosition: Int, length: Int) throws -> Int {
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        guard dataPosition >= 0, length >= 0,
              dataPosition <= bytes.count, length <= bytes.count - dataPosition else {
            throw POSIXError(.EINVAL)
        }
        guard length > 0 else { return 0 }
        let fd = self.fd
        try bytes.withUnsafeBytes { buf in
            // Non-nil: the range check above guarantees buf is non-empty.
            guard let base = buf.baseAddress else { throw POSIXError(.EINVAL) }
            var offset = dataPosition
            let end = dataPosition + length
            while offset < end {
                // Darwin's write(2) rejects nbyte > INT_MAX with EINVAL; write in pieces.
                let n = posixWrite(fd, base + offset, min(end - offset, Int(Int32.max)))
                if n < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                // write(2) returns 0 only for a zero-length request; don't spin.
                guard n > 0 else { throw POSIXError(.EIO) }
                offset += n
            }
        }
        return length
    }

    public func close() {
        guard fd >= 0 else { return }
        posixClose(fd)
        fd = -1
    }

    public func delete() {
        close()
        try? FileManager.default.removeItem(atPath: path)
    }

    deinit { close() }
}
