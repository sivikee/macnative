import Foundation
import Observation

/// Native Steam account state: login flow, the logged-on session, and the owned library.
@MainActor
@Observable
final class SteamStore {
    enum LoginStep: Equatable {
        case idle
        case working(String)
        case needsCode(email: Bool, canConfirmOnPhone: Bool, error: String?)
        case waitingForPhone
        case qr(url: String)
        case failed(String)
    }

    private(set) var account: SteamSession.Account? = SteamSession.loadAccount()
    private(set) var isOnline = false
    private(set) var isSyncing = false
    var loginStep: LoginStep = .idle
    private(set) var apps: [UInt32: SteamAppInfo] = [:]
    private(set) var ownership: SteamOwnership?

    private(set) var session = SteamSession()
    private var authSession: SteamAuth.Session?
    private var pollTask: Task<Void, Never>?
    /// Called after a successful sync so AppState can merge games.
    var onLibraryChanged: (() -> Void)?

    var isLoggedIn: Bool { account != nil }

    init() { loadCache() }

    // MARK: Cache (data/steam/library-cache.json)

    private static var cacheFile: URL {
        let dir = Paths.root.appendingPathComponent("steam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library-cache.json")
    }

    private struct Cache: Codable { var apps: [SteamAppInfo]; var ownership: SteamOwnership }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheFile),
              let c = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        apps = Dictionary(uniqueKeysWithValues: c.apps.map { ($0.appID, $0) })
        ownership = c.ownership
    }

    private func saveCache() {
        guard let ownership else { return }
        let c = Cache(apps: Array(apps.values), ownership: ownership)
        try? JSONEncoder().encode(c).write(to: Self.cacheFile, options: .atomic)
    }

    // MARK: Connect with the saved account

    func resume() async {
        guard let account, !isOnline else { return }
        do {
            try await logOn(account)
            await sync()
        } catch {
            // Offline is fine: the cached library still works for installed games.
            if let e = error as? SteamError, e.eresult == 5 || e.eresult == 8 || e.eresult == 84 {
                // Token revoked/expired: ask to sign in again.
                logout()
                loginStep = .failed("Your Steam session expired. Please sign in again.")
            }
        }
    }

    private func logOn(_ account: SteamSession.Account) async throws {
        await session.setDisconnectHandler { [weak self] in
            Task { @MainActor in self?.isOnline = false }
        }
        try await session.logOn(account)
        var saved = account
        let steamID = await session.connection.steamID
        if steamID != 0 { saved.steamID = steamID }
        self.account = saved
        SteamSession.saveAccount(saved)
        isOnline = true
    }

    /// Makes sure we're logged on before an operation that needs Steam (download, ticket…).
    func ensureOnline() async throws {
        if isOnline { return }
        guard let account else { throw SteamError(message: "Sign in to Steam in Settings → Accounts.") }
        session = SteamSession()
        try await logOn(account)
    }

    // MARK: Login

    func signIn(account name: String, password: String) {
        cancelLogin()
        loginStep = .working("Contacting Steam…")
        pollTask = Task {
            do {
                try await session.connectIfNeeded()
                let s = try await SteamAuth.beginWithCredentials(
                    session.connection, account: name, password: password, guardData: account?.guardData)
                authSession = s
                let codeTypes = s.allowed.filter { $0 == .deviceCode || $0 == .emailCode }
                let phone = s.allowed.contains(.deviceConfirmation)
                if let first = codeTypes.first {
                    loginStep = .needsCode(email: first == .emailCode, canConfirmOnPhone: phone, error: nil)
                } else if phone {
                    loginStep = .waitingForPhone
                } else {
                    loginStep = .working("Signing in…")
                }
                try await pollUntilDone()
            } catch is CancellationError {
            } catch {
                loginStep = .failed(error.localizedDescription)
            }
        }
    }

    func submitCode(_ code: String) {
        guard let s = authSession, case let .needsCode(email, phone, _) = loginStep else { return }
        loginStep = .working("Checking code…")
        Task {
            do {
                // On success the running poll loop picks up the tokens.
                try await SteamAuth.submitGuardCode(session.connection, session: s, code: code,
                                                    type: email ? .emailCode : .deviceCode)
            } catch {
                loginStep = .needsCode(email: email, canConfirmOnPhone: phone, error: error.localizedDescription)
            }
        }
    }

    func startQR() {
        cancelLogin()
        loginStep = .working("Creating QR code…")
        pollTask = Task {
            do {
                try await session.connectIfNeeded()
                let s = try await SteamAuth.beginWithQR(session.connection)
                authSession = s
                loginStep = .qr(url: s.challengeURL ?? "")
                try await pollUntilDone()
            } catch is CancellationError {
            } catch {
                loginStep = .failed(error.localizedDescription)
            }
        }
    }

    func cancelLogin() {
        pollTask?.cancel()
        pollTask = nil
        authSession = nil
        loginStep = .idle
    }

    private func pollUntilDone() async throws {
        while !Task.isCancelled, var s = authSession {
            try await Task.sleep(for: .seconds(max(s.interval, 1)))
            switch try await SteamAuth.poll(session.connection, session: &s) {
            case let .pending(newURL):
                authSession = s
                if let newURL, case .qr = loginStep { loginStep = .qr(url: newURL) }
            case let .done(tokens):
                loginStep = .working("Signing in…")
                let acct = SteamSession.Account(accountName: tokens.accountName, steamID: s.steamID,
                                                refreshToken: tokens.refreshToken, guardData: tokens.guardData)
                try await logOn(acct)
                authSession = nil
                loginStep = .idle
                await sync()
                return
            }
        }
    }

    func logout() {
        cancelLogin()
        let s = session
        Task { await s.logOff() }
        session = SteamSession()
        SteamSession.saveAccount(nil)
        account = nil
        isOnline = false
        apps = [:]
        ownership = nil
        try? FileManager.default.removeItem(at: Self.cacheFile)
        onLibraryChanged?()
    }

    // MARK: Library

    func sync() async {
        guard isOnline, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let owned = try await session.fetchOwnership()
            ownership = owned
            // Only fetch info for apps we haven't seen; refresh the rest on explicit refresh.
            let missing = owned.appIDs.filter { apps[$0] == nil }
            let infos = try await session.fetchAppInfo(Array(missing), tokens: owned.appTokens)
            for info in infos { apps[info.appID] = info }
            saveCache()
            onLibraryChanged?()
        } catch {
            // Keep whatever we had; a later sync will retry.
        }
    }

    /// Games to show: owned, Windows-capable, type "game".
    var ownedGames: [SteamAppInfo] {
        guard let ownership else { return [] }
        return apps.values.filter { ownership.appIDs.contains($0.appID) && $0.isGame && $0.runsOnWindows }
    }
}
