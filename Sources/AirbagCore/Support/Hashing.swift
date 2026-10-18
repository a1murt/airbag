import CryptoKit
import Foundation

public enum Hashing {
    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    public static func sha256(_ string: String) -> Data { sha256(Data(string.utf8)) }
    public static func sha256Hex(_ string: String) -> String { hex(sha256(string)) }

    /// Streams a file through SHA-256. Returns nil if the file cannot be opened or read.
    public static func sha256(fileAtPath path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let n = read(fd, buffer, size)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
        }
        return Data(hasher.finalize())
    }

    public static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for b in data {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
