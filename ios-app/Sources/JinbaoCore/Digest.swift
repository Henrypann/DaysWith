import Foundation
import CryptoKit

/// SHA-1 is required by the COS signature. SHA-256 identifies file bytes. Neither result is logged with a secret.
enum Digest {
    static func sha1(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0
        var bytes = message
        let bitLength = UInt64(message.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for index in 0..<16 {
                let start = offset + index * 4
                w[index] = (UInt32(bytes[start]) << 24) | (UInt32(bytes[start + 1]) << 16)
                    | (UInt32(bytes[start + 2]) << 8) | UInt32(bytes[start + 3])
            }
            for index in 16..<80 {
                let mixed = w[index - 3] ^ w[index - 8] ^ w[index - 14] ^ w[index - 16]
                w[index] = (mixed << 1) | (mixed >> 31)
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for index in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch index {
                case 0..<20:
                    f = (b & c) | (~b & d)
                    k = 0x5A827999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }
                let temp = rotateLeft(a, 5) &+ f &+ e &+ k &+ w[index]
                e = d
                d = c
                c = rotateLeft(b, 30)
                b = a
                a = temp
            }
            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }
        return words([h0, h1, h2, h3, h4])
    }

    static func sha256(_ message: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: Data(message))) }

    static func sha256Hex(_ data: Data) -> String { hex(Array(SHA256.hash(data: data))) }

    /// Bounded reads; media bytes are never accumulated in memory.
    static func sha256File(_ url: URL, maximumBytes: Int64 = V1Validator.maxResourceBytes) throws -> (hash: String, byteCount: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var count: Int64 = 0
        var finished = false
        while !finished {
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { finished = true; return }
                count += Int64(chunk.count)
                guard count <= maximumBytes else { throw CosFailure(.contentMismatch) }
                digest.update(data: chunk)
            }
        }
        return (hex(Array(digest.finalize())), count)
    }

    static func hmacSHA1(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var padded = key
        if padded.count > 64 { padded = sha1(padded) }
        if padded.count < 64 { padded.append(contentsOf: Array(repeating: 0, count: 64 - padded.count)) }
        let inner = sha1(padded.map { $0 ^ 0x36 } + message)
        return sha1(padded.map { $0 ^ 0x5c } + inner)
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func rotateLeft(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private static func words(_ values: [UInt32]) -> [UInt8] {
        values.flatMap { word in
            [UInt8((word >> 24) & 0xff), UInt8((word >> 16) & 0xff), UInt8((word >> 8) & 0xff), UInt8(word & 0xff)]
        }
    }
}
