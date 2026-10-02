import Foundation

/// A logged-on Steam session: owns the CM connection, keeps it alive, and exposes what the
/// rest of the app needs (licenses, PICS, depot keys, tickets).
actor SteamSession {
    struct Account: Codable {
        var accountName: String
        var steamID: UInt64
        var refreshToken: String
        var guardData: String?

        var accountID: UInt32 { UInt32(truncatingIfNeeded: steamID) }
    }

    struct License: Hashable {
        var packageID: UInt32
        var accessToken: UInt64
        var ownerID: UInt32
    }

    let connection = SteamConnection()
    private(set) var licenses: [License] = []
    private(set) var cellID: UInt32 = 0
    private var licenseWaiters: [CheckedContinuation<[License], Never>] = []
    private var heartbeat: Task<Void, Never>?
    private var eventPump: Task<Void, Never>?
    private(set) var isLoggedOn = false
    var onDisconnect: (@Sendable () -> Void)?

    // MARK: Account storage (inside MacNative's data folder, readable by this user only)

    static var accountFile: URL { Paths.accounts.appendingPathComponent("steam.json") }

    static func loadAccount() -> Account? {
        (try? Data(contentsOf: accountFile)).flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
    }

    static func saveAccount(_ a: Account?) {
        guard let a else { try? FileManager.default.removeItem(at: accountFile); return }
        try? JSONEncoder.pretty.encode(a).write(to: accountFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountFile.path)
    }

    // MARK: Logon

    func connectIfNeeded() async throws {
        if await connection.isConnected { return }
        try await connection.connect()
        startEventPump()
    }

    func setDisconnectHandler(_ h: @escaping @Sendable () -> Void) { onDisconnect = h }

    private var logonWaiter: CheckedContinuation<Void, Error>?

    /// Logs on with a refresh token from `SteamAuth` and waits for ClientLogOnResponse.
    /// Steam sends the license list right after a successful logon.
    func logOn(_ account: Account) async throws {
        try await connectIfNeeded()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            logonWaiter = c
            Task {
                do {
                    try await connection.send(.clientLogon, steamID: SteamConnection.anonymousUserSteamID) { w in
                        w.uint32(1, SteamConnection.protocolVersion)
                        w.message(11) { $0.fixed32(1, 0xBAAD_F00D) }
                        w.uint32(3, 0)
                        w.uint32(5, 1771)
                        w.string(6, "english")
                        w.int32(7, 0)
                        w.bool(8, true)
                        w.string(96, SteamAuth.deviceName)
                        w.bool(102, true)
                        w.string(108, account.refreshToken)
                    }
                } catch {
                    resumeLogon(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                resumeLogon(.failure(SteamError(message: "Steam logon timed out")))
            }
        }
    }

    private func resumeLogon(_ r: Result<Void, Error>) {
        logonWaiter?.resume(with: r)
        logonWaiter = nil
    }

    func logOff() async {
        if isLoggedOn { try? await connection.send(.clientLogOff) { _ in } }
        heartbeat?.cancel()
        isLoggedOn = false
        await connection.disconnect()
    }

    /// Returns licenses, waiting for the list Steam sends after logon if it hasn't arrived yet.
    func waitForLicenses() async -> [License] {
        if !licenses.isEmpty { return licenses }
        return await withCheckedContinuation { c in
            licenseWaiters.append(c)
            Task {
                try? await Task.sleep(for: .seconds(20))
                flushLicenseWaiters()
            }
        }
    }

    private func flushLicenseWaiters() {
        let waiters = licenseWaiters
        licenseWaiters = []
        for w in waiters { w.resume(returning: licenses) }
    }

    // MARK: Events

    private func startEventPump() {
        eventPump?.cancel()
        let events = connection.events
        eventPump = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: SteamConnection.Event) async {
        switch event {
        case .disconnected:
            heartbeat?.cancel()
            isLoggedOn = false
            resumeLogon(.failure(SteamError(message: "Lost connection to Steam")))
            onDisconnect?()
        case let .packet(p):
            switch EMsg(rawValue: p.emsg) {
            case .clientLogOnResponse:
                guard let body = try? ProtoMessage(p.body) else { return }
                let result = body.int32(1) ?? 2
                guard result == 1 else {
                    resumeLogon(.failure(SteamError.result(result, "Steam logon")))
                    return
                }
                cellID = body.uint32(7) ?? 0
                isLoggedOn = true
                startHeartbeat(seconds: Int(body.int32(3) ?? 9))
                resumeLogon(.success(()))
            case .clientLoggedOff:
                isLoggedOn = false
                heartbeat?.cancel()
            case .clientLicenseList:
                guard let body = try? ProtoMessage(p.body) else { return }
                licenses = body.messages(2).compactMap { l in
                    guard let id = l.uint32(1) else { return nil }
                    return License(packageID: id, accessToken: l.uint64(17) ?? 0, ownerID: l.uint32(12) ?? 0)
                }
                flushLicenseWaiters()
            default:
                break
            }
        }
    }

    private func startHeartbeat(seconds: Int) {
        heartbeat?.cancel()
        let connection = connection
        heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(seconds, 5)))
                try? await connection.send(.clientHeartBeat) { _ in }
            }
        }
    }
}
