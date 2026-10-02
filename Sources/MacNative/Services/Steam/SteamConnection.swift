import Foundation

/// Steam message ids used by MacNative (values from SteamDatabase/Protobufs enums_clientserver.proto).
enum EMsg: UInt32 {
    case multi = 1
    case serviceMethodResponse = 147
    case serviceMethodCallFromClient = 151
    case clientHeartBeat = 703
    case clientLogOff = 706
    case clientLogOnResponse = 751
    case clientLoggedOff = 757
    case clientLicenseList = 780
    case clientGetDepotDecryptionKey = 5438
    case clientGetDepotDecryptionKeyResponse = 5439
    case clientLogon = 5514
    case clientRequestEncryptedAppTicket = 5526
    case clientRequestEncryptedAppTicketResponse = 5527
    case clientPICSProductInfoRequest = 8903
    case clientPICSProductInfoResponse = 8904
    case clientPICSAccessTokenRequest = 8905
    case clientPICSAccessTokenResponse = 8906
    case serviceMethodCallFromClientNonAuthed = 9804
    case clientHello = 9805
}

struct SteamError: LocalizedError {
    var message: String
    var eresult: Int32?
    var errorDescription: String? { message }

    static func result(_ code: Int32, _ context: String) -> SteamError {
        let reason: String
        switch code {
        case 5: reason = "Invalid password"
        case 18: reason = "Account not found"
        case 63, 85: reason = "Steam Guard code required"
        case 65, 88: reason = "Wrong Steam Guard code"
        case 84: reason = "Too many attempts, try again later"
        case 9: reason = "File or app not found"
        case 15: reason = "Access denied"
        case 3: reason = "No connection to Steam"
        default: reason = "Steam error \(code)"
        }
        return SteamError(message: "\(context): \(reason)", eresult: code)
    }
}

/// One WebSocket connection to a Steam Connection Manager (CM).
///
/// Packet layout: `uint32 emsg | 0x80000000`, `int32 headerLength`, `CMsgProtoBufHeader`, body.
actor SteamConnection {
    struct Packet {
        var emsg: UInt32
        var header: ProtoMessage
        var body: Data
        var eresult: Int32 { header.int32(13) ?? 1 }
    }

    enum Event {
        case packet(Packet)
        case disconnected
    }

    static let protocolVersion: UInt32 = 65580
    /// SteamID used before logon: individual account, public universe, desktop instance, account 0.
    static let anonymousUserSteamID: UInt64 = 0x0110_0001_0000_0000

    nonisolated let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation

    private var socket: URLSessionWebSocketTask?
    private var nextJobID: UInt64 = 1
    private var jobs: [UInt64: Job] = [:]
    private(set) var steamID: UInt64 = 0
    private(set) var sessionID: Int32 = 0
    private(set) var isConnected = false

    private struct Job {
        var continuation: CheckedContinuation<[Packet], Error>
        var collected: [Packet] = []
        var isFinal: (Packet) -> Bool
    }

    init() {
        (events, eventSink) = AsyncStream.makeStream(of: Event.self)
    }

    // MARK: Connect

    func connect() async throws {
        let endpoints = try await Self.fetchEndpoints()
        var lastError: Error = SteamError(message: "No Steam servers available")
        for endpoint in endpoints.prefix(5) {
            guard let url = URL(string: "wss://\(endpoint)/cmsocket/") else { continue }
            let task = URLSession.shared.webSocketTask(with: url)
            task.maximumMessageSize = 64 << 20
            task.resume()
            do {
                socket = task
                startReceiving(task)
                try await send(.clientHello, steamID: 0) { $0.uint32(1, Self.protocolVersion) }
                // A short ping confirms the socket really opened.
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    task.sendPing { error in if let error { c.resume(throwing: error) } else { c.resume() } }
                }
                isConnected = true
                return
            } catch {
                lastError = error
                task.cancel(with: .goingAway, reason: nil)
                socket = nil
            }
        }
        throw lastError
    }

    func disconnect() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        isConnected = false
        failAllJobs(SteamError(message: "Disconnected from Steam"))
    }

    private static func fetchEndpoints() async throws -> [String] {
        let url = URL(string: "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0&cmprotocol=websockets")!
        let (data, _) = try await URLSession.shared.data(from: url)
        struct R: Decodable {
            struct Inner: Decodable { var serverlist: [Server] }
            struct Server: Decodable { var endpoint: String; var type: String }
            var response: Inner
        }
        return try JSONDecoder().decode(R.self, from: data).response.serverlist
            .filter { $0.type == "websockets" }.map(\.endpoint)
    }

    // MARK: Send

    func send(_ emsg: EMsg, steamID overrideSteamID: UInt64? = nil, jobID: UInt64? = nil,
              targetJobName: String? = nil, body build: (inout ProtoWriter) -> Void) async throws {
        var body = ProtoWriter()
        build(&body)
        try await sendRaw(emsg.rawValue, steamID: overrideSteamID, jobID: jobID, targetJobName: targetJobName, body: body.data)
    }

    private func sendRaw(_ emsg: UInt32, steamID overrideSteamID: UInt64?, jobID: UInt64?,
                         targetJobName: String?, body: Data) async throws {
        guard let socket else { throw SteamError(message: "Not connected to Steam") }
        var header = ProtoWriter()
        header.fixed64(1, overrideSteamID ?? steamID)
        header.int32(2, sessionID)
        if let jobID { header.fixed64(10, jobID) }
        if let targetJobName { header.string(12, targetJobName) }

        var packet = Data()
        packet.appendLE(emsg | 0x8000_0000)
        packet.appendLE(Int32(header.data.count))
        packet.append(header.data)
        packet.append(body)
        try await socket.send(.data(packet))
    }

    /// Sends a request tagged with a job id and waits for every response packet for that job.
    func job(_ emsg: EMsg, steamID overrideSteamID: UInt64? = nil, targetJobName: String? = nil,
             isFinal: @escaping (Packet) -> Bool = { _ in true },
             body build: (inout ProtoWriter) -> Void) async throws -> [Packet] {
        var body = ProtoWriter()
        build(&body)
        let jobID = nextJobID
        nextJobID += 1
        return try await withCheckedThrowingContinuation { c in
            jobs[jobID] = Job(continuation: c, isFinal: isFinal)
            Task {
                do {
                    try await sendRaw(emsg.rawValue, steamID: overrideSteamID, jobID: jobID,
                                      targetJobName: targetJobName, body: body.data)
                } catch {
                    finishJob(jobID, with: .failure(error))
                }
            }
            // Steam never answers some failures; don't hang forever.
            Task {
                try? await Task.sleep(for: .seconds(60))
                finishJob(jobID, with: .failure(SteamError(message: "Steam didn't respond in time")))
            }
        }
    }

    /// Calls a unified service method, e.g. `Authentication.BeginAuthSessionViaQR#1`.
    func call(_ method: String, authenticated: Bool = true,
              body build: (inout ProtoWriter) -> Void) async throws -> ProtoMessage {
        let emsg: EMsg = authenticated ? .serviceMethodCallFromClient : .serviceMethodCallFromClientNonAuthed
        let packets = try await job(emsg, steamID: authenticated ? nil : 0, targetJobName: method, body: build)
        guard let p = packets.last else { throw SteamError(message: "Empty response to \(method)") }
        guard p.eresult == 1 else {
            throw SteamError.result(p.eresult, method.components(separatedBy: ".").last?
                .components(separatedBy: "#").first ?? method)
        }
        return try ProtoMessage(p.body)
    }

    /// Sends a service notification (a method with no response).
    func notify(_ method: String, body build: (inout ProtoWriter) -> Void) async throws {
        var body = ProtoWriter()
        build(&body)
        try await sendRaw(EMsg.serviceMethodCallFromClient.rawValue, steamID: nil, jobID: nil,
                          targetJobName: method, body: body.data)
    }

    func setSession(steamID: UInt64, sessionID: Int32) {
        self.steamID = steamID
        self.sessionID = sessionID
    }

    // MARK: Receive

    private func startReceiving(_ task: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                do {
                    let message = try await task.receive()
                    if case let .data(data) = message { await self?.handle(data) }
                } catch {
                    await self?.connectionLost(task)
                    return
                }
            }
        }
    }

    private func connectionLost(_ task: URLSessionWebSocketTask) {
        guard task === socket else { return }
        socket = nil
        isConnected = false
        failAllJobs(SteamError(message: "Lost connection to Steam"))
        eventSink.yield(.disconnected)
    }

    private func handle(_ data: Data) {
        var r = ByteReader(data)
        guard let raw = try? r.uint32LE(), raw & 0x8000_0000 != 0,
              let headerLength = try? r.uint32LE(),
              let headerData = try? r.bytes(Int(headerLength)),
              let header = try? ProtoMessage(headerData) else { return }
        let emsg = raw & 0x7FFF_FFFF
        let body = data.subdata(in: r.offset..<data.endIndex)

        if emsg == EMsg.multi.rawValue {
            handleMulti(body)
            return
        }
        let packet = Packet(emsg: emsg, header: header, body: body)

        if emsg == EMsg.clientLogOnResponse.rawValue, packet.eresult == 1 {
            steamID = header.uint64(1) ?? steamID
            sessionID = header.int32(2) ?? sessionID
        }

        if let target = header.uint64(11), target != .max, var job = jobs[target] {
            job.collected.append(packet)
            jobs[target] = job
            if job.isFinal(packet) { finishJob(target, with: .success(job.collected)) }
            return
        }
        eventSink.yield(.packet(packet))
    }

    private func handleMulti(_ body: Data) {
        guard let multi = try? ProtoMessage(body), var payload = multi.bytes(2) else { return }
        if (multi.uint32(1) ?? 0) > 0 {
            guard let unzipped = Gzip.decompress(payload) else { return }
            payload = unzipped
        }
        var r = ByteReader(payload)
        while !r.isAtEnd, let length = try? r.uint32LE(), let sub = try? r.bytes(Int(length)) {
            handle(sub)
        }
    }

    private func finishJob(_ id: UInt64, with result: Result<[Packet], Error>) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.continuation.resume(with: result)
    }

    private func failAllJobs(_ error: Error) {
        for id in Array(jobs.keys) { finishJob(id, with: .failure(error)) }
    }
}

enum Gzip {
    /// Decompresses a gzip member using the system's raw-deflate decoder.
    static func decompress(_ data: Data) -> Data? {
        var r = ByteReader(data)
        guard (try? r.byte()) == 0x1F, (try? r.byte()) == 0x8B, (try? r.byte()) == 8,
              let flags = try? r.byte(), (try? r.bytes(6)) != nil else { return nil }
        if flags & 4 != 0, let lo = try? r.byte(), let hi = try? r.byte() { _ = try? r.bytes(Int(lo) | Int(hi) << 8) }
        if flags & 8 != 0 { _ = try? r.cString() }
        if flags & 16 != 0 { _ = try? r.cString() }
        if flags & 2 != 0 { _ = try? r.bytes(2) }
        guard r.remaining > 8 else { return nil }
        let deflate = data.subdata(in: r.offset..<data.endIndex - 8)
        return try? (deflate as NSData).decompressed(using: .zlib) as Data
    }
}
