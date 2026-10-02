import Foundation

/// Minimal protobuf wire-format encoder/decoder. Steam's messages are written by hand against
/// field numbers from https://github.com/SteamDatabase/Protobufs, which keeps MacNative free of
/// code generators and package dependencies.
struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, 0)
        appendVarint(value)
    }
    mutating func uint32(_ field: Int, _ value: UInt32) { varint(field, UInt64(value)) }
    mutating func int32(_ field: Int, _ value: Int32) { varint(field, UInt64(bitPattern: Int64(value))) }
    mutating func uint64(_ field: Int, _ value: UInt64) { varint(field, value) }
    mutating func bool(_ field: Int, _ value: Bool) { varint(field, value ? 1 : 0) }

    mutating func fixed64(_ field: Int, _ value: UInt64) {
        key(field, 1)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    mutating func fixed32(_ field: Int, _ value: UInt32) {
        key(field, 5)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    mutating func bytes(_ field: Int, _ value: Data) {
        key(field, 2)
        appendVarint(UInt64(value.count))
        data.append(value)
    }
    mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }
    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var w = ProtoWriter()
        build(&w)
        bytes(field, w.data)
    }

    private mutating func key(_ field: Int, _ wireType: UInt64) { appendVarint(UInt64(field) << 3 | wireType) }
    private mutating func appendVarint(_ v: UInt64) {
        var v = v
        while v >= 0x80 { data.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }
}

/// Decoded message: every occurrence of every field, in order.
struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }

    private(set) var fields: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        var r = ByteReader(data)
        while !r.isAtEnd {
            let key = try r.varint()
            let field = Int(key >> 3)
            let value: Value
            switch key & 7 {
            case 0: value = .varint(try r.varint())
            case 1: value = .fixed64(try r.uint64LE())
            case 2: value = .bytes(try r.bytes(Int(try r.varint())))
            case 5: value = .fixed32(try r.uint32LE())
            default: throw ProtoError.unsupportedWireType
            }
            fields[field, default: []].append(value)
        }
    }

    func uint64(_ f: Int) -> UInt64? {
        switch fields[f]?.last {
        case let .varint(v), let .fixed64(v): v
        case let .fixed32(v): UInt64(v)
        default: nil
        }
    }
    func uint32(_ f: Int) -> UInt32? { uint64(f).map { UInt32(truncatingIfNeeded: $0) } }
    func int32(_ f: Int) -> Int32? { uint64(f).map { Int32(truncatingIfNeeded: $0) } }
    func bool(_ f: Int) -> Bool? { uint64(f).map { $0 != 0 } }
    func float(_ f: Int) -> Float? {
        if case let .fixed32(v) = fields[f]?.last { return Float(bitPattern: v) }
        return nil
    }
    func bytes(_ f: Int) -> Data? {
        if case let .bytes(d) = fields[f]?.last { return d }
        return nil
    }
    func string(_ f: Int) -> String? { bytes(f).map { String(decoding: $0, as: UTF8.self) } }
    func message(_ f: Int) -> ProtoMessage? { bytes(f).flatMap { try? ProtoMessage($0) } }
    func messages(_ f: Int) -> [ProtoMessage] {
        (fields[f] ?? []).compactMap { if case let .bytes(d) = $0 { try? ProtoMessage(d) } else { nil } }
    }
    func uint32s(_ f: Int) -> [UInt32] {
        (fields[f] ?? []).flatMap { v -> [UInt32] in
            switch v {
            case let .varint(x): return [UInt32(truncatingIfNeeded: x)]
            case let .fixed32(x): return [x]
            case let .bytes(packed):
                var r = ByteReader(packed), out: [UInt32] = []
                while !r.isAtEnd, let x = try? r.varint() { out.append(UInt32(truncatingIfNeeded: x)) }
                return out
            default: return []
            }
        }
    }
}

enum ProtoError: Error { case truncated, unsupportedWireType }

/// Little-endian cursor over `Data`, shared by protobuf and Steam's binary formats.
struct ByteReader {
    let data: Data
    var offset: Int

    init(_ data: Data) { self.data = data; self.offset = data.startIndex }

    var isAtEnd: Bool { offset >= data.endIndex }
    var remaining: Int { data.endIndex - offset }

    mutating func byte() throws -> UInt8 {
        guard offset < data.endIndex else { throw ProtoError.truncated }
        defer { offset += 1 }
        return data[offset]
    }
    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, offset + n <= data.endIndex else { throw ProtoError.truncated }
        defer { offset += n }
        return data.subdata(in: offset..<offset + n)
    }
    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while true {
            let b = try byte()
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw ProtoError.truncated }
        }
    }
    mutating func uint32LE() throws -> UInt32 {
        let d = try bytes(4)
        return d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }
    mutating func uint64LE() throws -> UInt64 {
        let d = try bytes(8)
        return d.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }
    mutating func cString() throws -> String {
        var bytes: [UInt8] = []
        while true { let b = try byte(); if b == 0 { break }; bytes.append(b) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
