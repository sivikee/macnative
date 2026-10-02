import Foundation

/// GOG integration using the same public endpoints as GOG Galaxy, Heroic, Lutris and GameNative.
/// Games are installed by running their offline Windows installers silently inside a prefix.
enum GOGService {
    // Public GOG Galaxy client credentials, used by all open-source GOG launchers.
    static let clientID = "46899977096215655"
    static let clientSecret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
    static let redirectURI = "https://embed.gog.com/on_login_success?origin=client"

    static var loginURL: URL {
        var c = URLComponents(string: "https://auth.gog.com/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "layout", value: "client2"),
        ]
        return c.url!
    }

    struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var userID: String
        var expiresAt: Date
    }

    // MARK: Auth

    private static var sessionFile: URL { Paths.accounts.appendingPathComponent("gog.json") }

    static func loadSession() -> Session? {
        guard let data = try? Data(contentsOf: sessionFile) else { return nil }
        return try? JSONDecoder.iso.decode(Session.self, from: data)
    }

    static func saveSession(_ s: Session?) {
        guard let s else { try? FileManager.default.removeItem(at: sessionFile); return }
        try? JSONEncoder.pretty.encode(s).write(to: sessionFile, options: .atomic)
        // Tokens are credentials: keep them readable by this user only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionFile.path)
    }

    static func exchange(code: String) async throws -> Session {
        try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI])
    }

    /// Returns a session with a valid access token, refreshing it if needed.
    static func validSession() async throws -> Session {
        guard let s = loadSession() else { throw GOGError.notLoggedIn }
        if s.expiresAt > .now.addingTimeInterval(60) { return s }
        let fresh = try await token(["grant_type": "refresh_token", "refresh_token": s.refreshToken])
        saveSession(fresh)
        return fresh
    }

    private static func token(_ params: [String: String]) async throws -> Session {
        var c = URLComponents(string: "https://auth.gog.com/token")!
        c.queryItems = (["client_id": clientID, "client_secret": clientSecret].merging(params) { $1 })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        struct R: Decodable { var access_token: String; var refresh_token: String; var user_id: String; var expires_in: Double }
        let r = try JSONDecoder().decode(R.self, from: data)
        return Session(accessToken: r.access_token, refreshToken: r.refresh_token, userID: r.user_id,
                       expiresAt: .now.addingTimeInterval(r.expires_in))
    }

    private static func authorized(_ url: URL) async throws -> Data {
        let s = try await validSession()
        var req = URLRequest(url: url)
        req.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw GOGError.notLoggedIn }
        return data
    }

    // MARK: Library

    struct OwnedGame {
        var id: String
        var title: String
        var coverURL: URL?
        var heroURL: URL?
        var supportsWindows: Bool
    }

    static func ownedGames() async throws -> [OwnedGame] {
        var result: [OwnedGame] = []
        var page = 1
        var totalPages = 1
        repeat {
            let url = URL(string: "https://embed.gog.com/account/getFilteredProducts?mediaType=1&sortBy=title&page=\(page)")!
            let data = try await authorized(url)
            struct Page: Decodable {
                struct Product: Decodable {
                    struct WorksOn: Decodable { var Windows: Bool }
                    var id: Int; var title: String; var image: String; var worksOn: WorksOn
                }
                var totalPages: Int
                var products: [Product]
            }
            let p = try JSONDecoder().decode(Page.self, from: data)
            totalPages = p.totalPages
            result += p.products.map { prod in
                // `image` is a protocol-relative base like //images-1.gog-statics.com/<hash>.
                let base = "https:\(prod.image)"
                return OwnedGame(id: String(prod.id), title: prod.title,
                                 coverURL: nil, heroURL: URL(string: "\(base).jpg"),
                                 supportsWindows: prod.worksOn.Windows)
            }
            page += 1
        } while page <= totalPages
        return result
    }

    struct Metadata { var coverURL: URL?; var heroURL: URL?; var year: Int? }

    /// Galaxy's games database has the portrait covers used for library grids.
    static func metadata(gameID: String) async -> Metadata? {
        guard let url = URL(string: "https://gamesdb.gog.com/platforms/gog/external_releases/\(gameID)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let game = root["game"] as? [String: Any]
        func image(_ key: String, _ formatter: String, _ ext: String) -> URL? {
            guard let format = (game?[key] as? [String: Any])?["url_format"] as? String else { return nil }
            return URL(string: format.replacingOccurrences(of: "{formatter}", with: formatter)
                .replacingOccurrences(of: "{ext}", with: ext))
        }
        let year = (root["first_release_date"] as? String).flatMap { Int($0.prefix(4)) }
        return Metadata(coverURL: image("vertical_cover", "_glx_vertical_cover", "webp"),
                        heroURL: image("cover", "", "jpg"), year: year)
    }

    struct InstallerFile { var id: String; var size: Int64; var downlink: URL }

    /// Picks the Windows offline installer (prefers English) and returns its file parts.
    static func installerFiles(gameID: String) async throws -> [InstallerFile] {
        let data = try await authorized(URL(string: "https://api.gog.com/products/\(gameID)?expand=downloads")!)
        struct Product: Decodable {
            struct Downloads: Decodable { var installers: [Installer] }
            struct Installer: Decodable {
                struct File: Decodable { var id: String; var size: Int64; var downlink: URL }
                var os: String; var language: String; var files: [File]
            }
            var downloads: Downloads
        }
        let product = try JSONDecoder().decode(Product.self, from: data)
        let windows = product.downloads.installers.filter { $0.os == "windows" }
        guard let installer = windows.first(where: { $0.language == "en" }) ?? windows.first else {
            throw GOGError.noWindowsInstaller
        }
        return installer.files.map { InstallerFile(id: $0.id, size: $0.size, downlink: $0.downlink) }
    }

    /// `downlink` is an API URL that returns the real, signed CDN URL.
    static func resolveDownlink(_ url: URL) async throws -> URL {
        let data = try await authorized(url)
        struct R: Decodable { var downlink: URL }
        return try JSONDecoder().decode(R.self, from: data).downlink
    }

    struct PlayTask { var path: String; var workingDir: String?; var arguments: String? }

    /// GOG installers drop `goggame-<id>.info` describing how to launch the game.
    static func primaryPlayTask(installDir: URL, gameID: String) -> PlayTask? {
        let fm = FileManager.default
        var infoFile = installDir.appendingPathComponent("goggame-\(gameID).info")
        if !fm.fileExists(atPath: infoFile.path),
           let any = (try? fm.contentsOfDirectory(atPath: installDir.path))?
               .first(where: { $0.hasPrefix("goggame-") && $0.hasSuffix(".info") }) {
            infoFile = installDir.appendingPathComponent(any)
        }
        struct Info: Decodable {
            struct Task: Decodable {
                var isPrimary: Bool?; var type: String?; var path: String?
                var workingDir: String?; var arguments: String?
            }
            var playTasks: [Task]?
        }
        guard let data = try? Data(contentsOf: infoFile),
              let info = try? JSONDecoder().decode(Info.self, from: data) else { return nil }
        let tasks = (info.playTasks ?? []).filter { $0.type == "FileTask" && $0.path != nil }
        guard let t = tasks.first(where: { $0.isPrimary == true }) ?? tasks.first else { return nil }
        return PlayTask(path: t.path!, workingDir: t.workingDir, arguments: t.arguments)
    }

    enum GOGError: LocalizedError {
        case notLoggedIn, noWindowsInstaller, noExecutable
        var errorDescription: String? {
            switch self {
            case .notLoggedIn: "Sign in to GOG in Settings → Accounts."
            case .noWindowsInstaller: "This game has no Windows installer on GOG."
            case .noExecutable: "Couldn't find the game's executable. Pick it in the game's settings (⚙︎ → Launch)."
            }
        }
    }
}
