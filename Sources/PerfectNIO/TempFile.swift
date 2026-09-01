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

    public var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public init(withPrefix prefix: String) {
        let template = prefix + "XXXXXX"
        let capacity = template.utf8.count + 1
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buf.deallocate() }
        template.withCString { src in _ = memcpy(buf, src, capacity) }
        fd = mkstemp(buf)
        path = fd >= 0 ? String(cString: buf) : ""
    }

    @discardableResult
    public func write(bytes: [UInt8], dataPosition: Int, length: Int) throws -> Int {
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        let written = bytes.withUnsafeBytes { ptr in
            posixWrite(fd, ptr.baseAddress!.advanced(by: dataPosition), length)
        }
        guard written >= 0 else { throw POSIXError(.EIO) }
        return written
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
