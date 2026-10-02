import Foundation

/// A depot manifest: the files of one depot version and the chunks they're made of.
struct DepotManifest {
    struct Chunk: Hashable {
        var sha: Data
        var checksum: UInt32
        var offset: UInt64
        var size: Int
        var compressedSize: Int
    }

    struct File {
        var path: String            // forward slashes, relative to the install dir
        var size: UInt64
        var flags: UInt32
        var sha: Data
        var chunks: [Chunk]
        var linkTarget: String?

        var isDirectory: Bool { flags & 64 != 0 }
        var isSymlink: Bool { flags & 512 != 0 || (linkTarget?.isEmpty == false) }
    }

    var depotID: UInt32
    var gid: UInt64
    var files: [File]
    var totalSize: UInt64 { files.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) } }

    private static let payloadMagic: UInt32 = 0x71F6_17D0
    private static let metadataMagic: UInt32 = 0x1F48_12BE
    private static let signatureMagic: UInt32 = 0x1B81_B817
    private static let endMagic: UInt32 = 0x32C4_15AB

    /// Parses the (unzipped) manifest: magic+length framed protobuf sections.
    init(_ data: Data, depotID: UInt32, gid: UInt64, key: Data) throws {
        var r = ByteReader(data)
        var payload: ProtoMessage?
        var metadata: ProtoMessage?
        while !r.isAtEnd {
            let magic = try r.uint32LE()
            if magic == Self.endMagic { break }
            let length = Int(try r.uint32LE())
            let section = try r.bytes(length)
            switch magic {
            case Self.payloadMagic: payload = try ProtoMessage(section)
            case Self.metadataMagic: metadata = try ProtoMessage(section)
            case Self.signatureMagic: break
            default: throw DepotChunk.ChunkError.format("manifest section \(String(magic, radix: 16))")
            }
        }
        guard let payload else { throw DepotChunk.ChunkError.format("manifest without payload") }
        let encryptedNames = metadata?.bool(4) ?? false

        self.depotID = depotID
        self.gid = gid
        files = try payload.messages(1).map { m in
            var name = m.string(1) ?? ""
            if encryptedNames {
                guard let raw = Data(base64Encoded: name.replacingOccurrences(of: "\n", with: "")) else {
                    throw DepotChunk.ChunkError.decrypt
                }
                let plain = try DepotChunk.decrypt(raw, key: key)
                name = String(decoding: plain.prefix { $0 != 0 }, as: UTF8.self)
            }
            let chunks = m.messages(6).map { c in
                Chunk(sha: c.bytes(1) ?? Data(), checksum: c.uint32(2) ?? 0, offset: c.uint64(3) ?? 0,
                      size: Int(c.uint32(4) ?? 0), compressedSize: Int(c.uint32(5) ?? 0))
            }.sorted { $0.offset < $1.offset }
            return File(path: name.replacingOccurrences(of: "\\", with: "/"), size: m.uint64(2) ?? 0,
                        flags: m.uint32(3) ?? 0, sha: m.bytes(5) ?? Data(), chunks: chunks,
                        linkTarget: m.string(7))
        }
    }
}

/// Talks to Steam's content servers ("SteamPipe").
struct SteamCDN {
    struct Server: Hashable {
        var host: String
        var https: Bool
    }

    let servers: [Server]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 16
        c.timeoutIntervalForRequest = 30
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    static func discover(_ steam: SteamSession) async throws -> SteamCDN {
        let cell = await steam.cellID
        let r = try await steam.connection.call("ContentServerDirectory.GetServersForSteamPipe#1") { w in
            w.uint32(1, cell)
            w.uint32(2, 20)
        }
        let servers = r.messages(1).compactMap { s -> Server? in
            guard let host = s.string(8) ?? s.string(9),
                  ["CDN", "SteamCache"].contains(s.string(1) ?? ""),
                  !(s.bool(10) ?? false), !(s.bool(7) ?? false) else { return nil }
            return Server(host: host, https: (s.string(12) ?? "") != "unavailable")
        }
        guard !servers.isEmpty else { throw SteamError(message: "No Steam content servers available") }
        return SteamCDN(servers: servers)
    }

    private func url(_ server: Server, _ path: String) -> URL {
        URL(string: "\(server.https ? "https" : "http")://\(server.host)/\(path)")!
    }

    /// Fetches `path`, trying other servers on failure.
    private func fetch(_ path: String, startAt index: Int = 0) async throws -> Data {
        var lastError: Error = SteamError(message: "Steam content download failed")
        for attempt in 0..<min(servers.count * 2, 8) {
            try Task.checkCancellation()
            let server = servers[(index + attempt) % servers.count]
            do {
                let (data, response) = try await session.data(from: url(server, path))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return data }
                lastError = SteamError(message: "Steam content server returned HTTP \(status)")
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }

    func manifest(depotID: UInt32, gid: UInt64, requestCode: UInt64, key: Data) async throws -> DepotManifest {
        let path = requestCode != 0
            ? "depot/\(depotID)/manifest/\(gid)/5/\(requestCode)"
            : "depot/\(depotID)/manifest/\(gid)/5"
        let zipped = try await fetch(path)
        return try DepotManifest(Zip.firstEntry(zipped), depotID: depotID, gid: gid, key: key)
    }

    func chunk(depotID: UInt32, _ c: DepotManifest.Chunk, key: Data, serverHint: Int) async throws -> Data {
        var lastError: Error = DepotChunk.ChunkError.checksum
        // A corrupt response from one server shouldn't fail the install: retry elsewhere.
        for attempt in 0..<3 {
            let raw = try await fetch("depot/\(depotID)/chunk/\(c.sha.hexString)", startAt: serverHint + attempt)
            do {
                return try DepotChunk.process(raw, key: key, expectedSize: c.size, checksum: c.checksum)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

extension SteamSession {
    func depotKey(depotID: UInt32, appID: UInt32) async throws -> Data {
        let packets = try await connection.job(.clientGetDepotDecryptionKey) { w in
            w.uint32(1, depotID)
            w.uint32(2, appID)
        }
        guard let p = packets.last, let body = try? ProtoMessage(p.body) else {
            throw SteamError(message: "No depot key from Steam")
        }
        let result = body.int32(1) ?? 2
        guard result == 1, let key = body.bytes(3) else { throw SteamError.result(result, "Depot \(depotID) key") }
        return key
    }

    func manifestRequestCode(appID: UInt32, depotID: UInt32, gid: UInt64, branch: String = "public") async throws -> UInt64 {
        let r = try await connection.call("ContentServerDirectory.GetManifestRequestCode#1") { w in
            w.uint32(1, appID)
            w.uint32(2, depotID)
            w.uint64(3, gid)
            w.string(4, branch)
        }
        return r.uint64(1) ?? 0
    }

    /// Serialized `EncryptedAppTicket` proving ownership; gbe_fork passes it to games that check it.
    func encryptedAppTicket(appID: UInt32) async throws -> Data? {
        let packets = try await connection.job(.clientRequestEncryptedAppTicket) { w in
            w.uint32(1, appID)
        }
        guard let p = packets.last, let body = try? ProtoMessage(p.body), body.int32(2) == 1 else { return nil }
        return body.bytes(3)
    }
}
