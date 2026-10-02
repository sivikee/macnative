import Foundation

/// Valve's binary KeyValues format (used for PICS package info).
enum BinaryVDF {
    static func parse(_ data: Data) -> VDF.Node? {
        var r = ByteReader(data)
        return try? .object(readObject(&r))
    }

    private static func readObject(_ r: inout ByteReader) throws -> [(String, VDF.Node)] {
        var pairs: [(String, VDF.Node)] = []
        while !r.isAtEnd {
            let type = try r.byte()
            if type == 8 || type == 11 { break }           // end of object
            let name = try r.cString()
            switch type {
            case 0: pairs.append((name, .object(try readObject(&r))))
            case 1: pairs.append((name, .value(try r.cString())))
            case 2, 4, 6: pairs.append((name, .value(String(Int32(bitPattern: try r.uint32LE())))))
            case 3: pairs.append((name, .value(String(Float(bitPattern: try r.uint32LE())))))
            case 7: pairs.append((name, .value(String(try r.uint64LE()))))
            case 10: pairs.append((name, .value(String(Int64(bitPattern: try r.uint64LE())))))
            case 5:                                        // wide string: UTF-16LE, null terminated
                var units: [UInt16] = []
                while true {
                    let lo = try r.byte(), hi = try r.byte()
                    let u = UInt16(lo) | UInt16(hi) << 8
                    if u == 0 { break }
                    units.append(u)
                }
                pairs.append((name, .value(String(decoding: units, as: UTF16.self))))
            default:
                throw ProtoError.unsupportedWireType
            }
        }
        return pairs
    }
}
