import Foundation
import CommonCrypto
import CryptoKit
import CLzma
import CZstd

/// Decrypts, decompresses and verifies Steam depot data (format as in SteamKit2's DepotChunk).
enum DepotChunk {
    enum ChunkError: LocalizedError {
        case decrypt, format(String), checksum
        var errorDescription: String? {
            switch self {
            case .decrypt: "Couldn't decrypt Steam content (wrong depot key?)"
            case let .format(s): "Unexpected Steam content format: \(s)"
            case .checksum: "Downloaded Steam content failed verification"
            }
        }
    }

    /// Steam's symmetric scheme: first 16 bytes are the IV encrypted with AES-256-ECB,
    /// the rest is AES-256-CBC with PKCS#7 padding.
    static func decrypt(_ data: Data, key: Data) throws -> Data {
        guard data.count > 16, key.count == 32 else { throw ChunkError.decrypt }
        let iv = try aes(CCOperation(kCCDecrypt), CCOptions(kCCOptionECBMode), key: key, iv: nil, data.prefix(16))
        return try aes(CCOperation(kCCDecrypt), CCOptions(kCCOptionPKCS7Padding), key: key, iv: iv, data.dropFirst(16))
    }

    private static func aes(_ op: CCOperation, _ options: CCOptions, key: Data, iv: Data?, _ input: Data) throws -> Data {
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    (iv ?? Data()).withUnsafeBytes { v in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), options,
                                k.baseAddress, key.count, iv == nil ? nil : v.baseAddress,
                                i.baseAddress, input.count, o.baseAddress, o.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ChunkError.decrypt }
        out.count = written
        return out
    }

    /// Full pipeline for one chunk: decrypt → decompress → check length and Adler-32.
    static func process(_ data: Data, key: Data, expectedSize: Int, checksum: UInt32) throws -> Data {
        let decrypted = try decrypt(data, key: key)
        let out = try decompress(decrypted, expectedSize: expectedSize)
        guard out.count == expectedSize, adler32(out) == checksum else { throw ChunkError.checksum }
        return out
    }

    static func decompress(_ d: Data, expectedSize: Int) throws -> Data {
        let b = [UInt8](d.prefix(4))
        if b.starts(with: [0x56, 0x53, 0x5A, 0x61]) { return try vzstd(d) }      // "VSZa"
        if b.starts(with: [0x56, 0x5A, 0x61]) { return try vzip(d) }            // "VZa"
        if b.starts(with: [0x50, 0x4B]) { return try Zip.firstEntry(d) }        // "PK"
        throw ChunkError.format("unknown header")
    }

    /// Valve's VZip: "VZ" 'a' | u32 crc/timestamp | 5 bytes LZMA props | data | u32 crc | u32 size | "zv".
    private static func vzip(_ d: Data) throws -> Data {
        guard d.count > 7 + 5 + 10 else { throw ChunkError.format("vzip too short") }
        let props = [UInt8](d[d.startIndex + 7 ..< d.startIndex + 12])
        let footer = d.endIndex - 10
        let size = Int(d.subdata(in: footer + 4 ..< footer + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let compressed = d.subdata(in: d.startIndex + 12 ..< footer)

        var out = Data(count: size)
        var destLen = SizeT(size)
        var srcLen = SizeT(compressed.count)
        var status = ELzmaStatus(rawValue: 0)
        let result = out.withUnsafeMutableBytes { o in
            compressed.withUnsafeBytes { c in
                props.withUnsafeBufferPointer { p in
                    LzmaDecode(o.bindMemory(to: UInt8.self).baseAddress, &destLen,
                               c.bindMemory(to: UInt8.self).baseAddress, &srcLen,
                               p.baseAddress, UInt32(LZMA_PROPS_SIZE), LZMA_FINISH_END, &status, &lzmaAlloc)
                }
            }
        }
        guard result == SZ_OK, Int(destLen) == size else { throw ChunkError.format("lzma \(result)") }
        return out
    }

    /// Valve's zstd wrapper: "VSZa" | u32 crc | zstd frame | u32 crc | u32 size | 4 bytes | "zsv".
    private static func vzstd(_ d: Data) throws -> Data {
        guard d.count > 8 + 15 else { throw ChunkError.format("vzstd too short") }
        let sizeAt = d.endIndex - 11
        let size = Int(d.subdata(in: sizeAt ..< sizeAt + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let frame = d.subdata(in: d.startIndex + 8 ..< d.endIndex - 15)
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { o in
            frame.withUnsafeBytes { f in ZSTD_decompress(o.baseAddress, size, f.baseAddress, frame.count) }
        }
        guard ZSTD_isError(written) == 0, written == size else { throw ChunkError.format("zstd") }
        return out
    }

    /// Adler-32 with a zero seed, as Steam uses for chunk checksums.
    static func adler32(_ data: Data) -> UInt32 {
        var s1: UInt32 = 0, s2: UInt32 = 0
        data.withUnsafeBytes { raw in
            var p = raw.bindMemory(to: UInt8.self)[...]
            while !p.isEmpty {
                let n = min(p.count, 5552)
                for b in p.prefix(n) { s1 &+= UInt32(b); s2 &+= s1 }
                s1 %= 65521; s2 %= 65521
                p = p.dropFirst(n)
            }
        }
        return s2 << 16 | s1
    }

    static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }
}

// LZMA SDK allocator callbacks.
private var lzmaAlloc = ISzAlloc(
    Alloc: { _, size in malloc(size) },
    Free: { _, address in free(address) })

/// Just enough ZIP reading for Steam manifests and PKZip chunks: the first entry, stored or deflated.
enum Zip {
    static func firstEntry(_ d: Data) throws -> Data {
        var r = ByteReader(d)
        // Prefer the central directory: local headers may defer sizes to a data descriptor.
        guard let eocd = findEOCD(d) else { throw DepotChunk.ChunkError.format("zip: no directory") }
        r.offset = eocd + 16
        let cdOffset = Int(try r.uint32LE())
        r.offset = d.startIndex + cdOffset
        guard try r.uint32LE() == 0x0201_4B50 else { throw DepotChunk.ChunkError.format("zip: bad directory") }
        r.offset += 6
        let method = try le16(&r)
        r.offset += 8
        let compSize = Int(try r.uint32LE())
        let size = Int(try r.uint32LE())
        r.offset += 4 + 2 + 2 + 2 + 2 + 4
        let localOffset = Int(try r.uint32LE())

        r.offset = d.startIndex + localOffset
        guard try r.uint32LE() == 0x0403_4B50 else { throw DepotChunk.ChunkError.format("zip: bad entry") }
        r.offset += 22
        let nameLen = Int(try le16(&r)), extraLen = Int(try le16(&r))
        r.offset += nameLen + extraLen
        let payload = try r.bytes(compSize)
        switch method {
        case 0: return payload
        case 8:
            guard let out = try? (payload as NSData).decompressed(using: .zlib) as Data, out.count == size else {
                throw DepotChunk.ChunkError.format("zip: inflate")
            }
            return out
        default: throw DepotChunk.ChunkError.format("zip: method \(method)")
        }
    }

    private static func le16(_ r: inout ByteReader) throws -> UInt16 {
        let b = try r.bytes(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }

    private static func findEOCD(_ d: Data) -> Int? {
        guard d.count >= 22 else { return nil }
        var i = d.endIndex - 22
        let stop = max(d.startIndex, d.endIndex - 22 - 65535)
        while i >= stop {
            if d[i] == 0x50, d[i + 1] == 0x4B, d[i + 2] == 0x05, d[i + 3] == 0x06 { return i }
            i -= 1
        }
        return nil
    }
}
