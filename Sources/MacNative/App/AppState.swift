import Foundation
import Observation
import AppKit

struct AppSettings: Codable {
    var defaultEngineID: String?
    var defaultConfig = GameConfig.default
    var verboseWineLogging = false
    var keepInstallers = false
    var hasCompletedSetup = false
}

/// A long-running job shown in the UI (engine download, game install, …).
struct Activity: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    /// 0…1, or nil while indeterminate.
    var progress: Double?
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, installed, favorites, steam, gog, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .installed: "Installed"
        case .favorites: "Favorites"
        case .steam: "Steam"
        case .gog: "GOG"
        case .custom: "Custom"
        }
    }
    var symbol: String? { self == .favorites ? "heart.fill" : nil }
}

enum Route: Equatable {
    case library
    case game(String)
    case settings
}

@MainActor
@Observable
final class AppState {
    var settings = AppSettings() { didSet { saveSettings() } }
    private(set) var games: [Game] = []
    let engines = EngineManager()

    var route: Route = .library
    var filter: LibraryFilter = .all
    var search = ""
    var isSearching = false
    /// Index of the highlighted card in the visible grid (keyboard / controller navigation).
    var focusedIndex = 0
    /// Column count of the library grid, reported by the view for up/down navigation.
    var gridColumns = 5
    var detailFocus = 0
    var showGameSettings = false
    var settingsSection: SettingsSection = .defaults
    var controllerName: String?
    /// Set once the user navigates with a controller or arrow keys; the focus ring only shows then.
    var controllerOrKeyboardActive = false
    var showAddGame = false
    var showGOGLogin = false
    var showSetup = false

    private(set) var activities: [String: Activity] = [:]
    /// Cancellable background jobs, keyed like `activities`.
    private(set) var jobs: [String: Task<Void, Never>] = [:]
    private(set) var running: Set<String> = []
    private var processes: [String: Process] = [:]
    private var steamClientConfig: GameConfig?
    var toast: String?

    var isGOGLoggedIn = GOGService.loadSession() != nil
    var rosettaInstalled = SystemCheck.isRosettaInstalled

    init() {
        loadSettings()
        loadLibrary()
        showSetup = !settings.hasCompletedSetup || engines.installed.isEmpty || !rosettaInstalled
    }

    // MARK: Library queries

    var visibleGames: [Game] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return games.filter { g in
            switch filter {
            case .all: true
            case .installed: g.isInstalled
            case .favorites: g.isFavorite
            case .steam: g.source == .steam
            case .gog: g.source == .gog
            case .custom: g.source == .custom
            }
        }
        .filter { q.isEmpty || $0.title.lowercased().contains(q) }
        .sorted { a, b in
            if a.isInstalled != b.isInstalled { return a.isInstalled }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    var focusedGame: Game? {
        let list = visibleGames
        return list.indices.contains(focusedIndex) ? list[focusedIndex] : list.first
    }

    func game(_ id: String) -> Game? { games.first { $0.id == id } }

    func update(_ id: String, _ change: (inout Game) -> Void) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        change(&games[i])
        saveLibrary()
    }

    // MARK: Persistence

    private func loadSettings() {
        if let data = try? Data(contentsOf: Paths.settingsFile),
           let s = try? JSONDecoder.iso.decode(AppSettings.self, from: data) { settings = s }
    }

    private func saveSettings() {
        try? JSONEncoder.pretty.encode(settings).write(to: Paths.settingsFile, options: .atomic)
    }

    private func loadLibrary() {
        if let data = try? Data(contentsOf: Paths.libraryFile),
           let g = try? JSONDecoder.iso.decode([Game].self, from: data) { games = g }
    }

    private func saveLibrary() {
        try? JSONEncoder.pretty.encode(games).write(to: Paths.libraryFile, options: .atomic)
    }

    // MARK: Activities

    private func setActivity(_ id: String, _ title: String, _ detail: String, _ progress: Double?) {
        activities[id] = Activity(id: id, title: title, detail: detail, progress: progress)
    }

    private func endActivity(_ id: String) { activities[id] = nil }

    /// Progress callbacks arrive asynchronously; ignore any that land after the job ended or was cancelled.
    private func updateProgress(_ id: String, _ title: String, _ detail: String, _ progress: Double?) {
        guard activities[id] != nil, jobs[id]?.isCancelled != true else { return }
        setActivity(id, title, detail, progress)
    }

    private func progressHandler(_ id: String, _ title: String, _ detail: String) -> Downloader.Progress {
        { [weak self] received, total in
            let fraction = total > 0 ? Double(received) / Double(total) : nil
            let text = total > 0 ? "\(detail) · \(Format.bytes(received)) of \(Format.bytes(total))" : detail
            Task { @MainActor in self?.updateProgress(id, title, text, fraction) }
        }
    }

    func report(_ error: Error) {
        guard !Self.isCancellation(error) else { return }
        toast = error.localizedDescription
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: Jobs

    /// Runs `work` as a cancellable job. Only one job per id at a time.
    private func startJob(_ id: String, _ work: @escaping @MainActor () async -> Void) {
        guard jobs[id] == nil else { return }
        jobs[id] = Task { @MainActor [weak self] in
            await work()
            self?.jobs[id] = nil
        }
    }

    func canCancel(_ id: String) -> Bool { jobs[id] != nil && jobs[id]?.isCancelled == false }

    func cancelJob(_ id: String) {
        guard let job = jobs[id], !job.isCancelled else { return }
        job.cancel()
        if var a = activities[id] {
            a.detail = "Cancelling…"
            a.progress = nil
            activities[id] = a
        }
    }

    // MARK: Setup

    func bootstrap() async {
        await engines.refreshCatalog()
        await refreshLibraries()
    }

    func installRosetta() async {
        setActivity("rosetta", "Rosetta 2", "Waiting for administrator approval…", nil)
        defer { endActivity("rosetta") }
        do {
            try await SystemCheck.installRosetta()
        } catch {
            report(error)
        }
        rosettaInstalled = SystemCheck.isRosettaInstalled
    }

    func installEngine(_ release: EngineRelease) {
        startJob("engine:\(release.id)") { [weak self] in await self?.runEngineInstall(release) }
    }

    private func runEngineInstall(_ release: EngineRelease) async {
        let id = "engine:\(release.id)"
        setActivity(id, release.name, "Downloading…", 0)
        defer { endActivity(id) }
        do {
            try await engines.install(release, progress: progressHandler(id, release.name, "Downloading"))
            if settings.defaultEngineID == nil { settings.defaultEngineID = release.id }
        } catch {
            report(error)
        }
    }

    // MARK: Library sync

    func refreshLibraries() async {
        await syncSteam()
        await syncGOG()
    }

    func syncSteam() async {
        let apps = SteamService.scanLibrary()
        for app in apps {
            let id = "steam:\(app.appID)"
            if let i = games.firstIndex(where: { $0.id == id }) {
                games[i].installState = app.installed ? .installed : .notInstalled
                games[i].installDirectory = app.installDir?.path
                games[i].installSizeBytes = app.sizeOnDisk
                if let n = app.name { games[i].title = n }
            } else if let name = app.name {
                games.append(newGame(id: id, source: .steam, externalID: app.appID, title: name,
                                     prefix: SteamService.prefixName) {
                    $0.installState = app.installed ? .installed : .notInstalled
                    $0.installDirectory = app.installDir?.path
                    $0.installSizeBytes = app.sizeOnDisk
                })
            } else if let details = await SteamService.storeDetails(app.appID), details.isGame {
                games.append(newGame(id: id, source: .steam, externalID: app.appID, title: details.name,
                                     prefix: SteamService.prefixName) {
                    $0.developer = details.developer
                    $0.releaseYear = details.year
                })
            }
        }
        // Drop Steam entries that disappeared from the client (e.g. after a reinstall).
        let known = Set(apps.map { "steam:\($0.appID)" })
        games.removeAll { $0.source == .steam && !known.contains($0.id) }
        saveLibrary()
    }

    func syncGOG() async {
        guard isGOGLoggedIn else { return }
        do {
            let owned = try await GOGService.ownedGames().filter(\.supportsWindows)
            for o in owned where !games.contains(where: { $0.id == "gog:\(o.id)" }) {
                games.append(newGame(id: "gog:\(o.id)", source: .gog, externalID: o.id, title: o.title,
                                     prefix: "gog-\(o.id)") { $0.heroURL = o.heroURL })
            }
            saveLibrary()
            for g in games where g.source == .gog && g.coverURL == nil {
                if let meta = await GOGService.metadata(gameID: g.externalID) {
                    update(g.id) {
                        $0.coverURL = meta.coverURL
                        $0.heroURL = meta.heroURL ?? $0.heroURL
                        $0.releaseYear = meta.year
                    }
                }
            }
        } catch GOGService.GOGError.notLoggedIn {
            logoutGOG()
        } catch {
            report(error)
        }
    }

    private func newGame(id: String, source: GameSource, externalID: String, title: String,
                         prefix: String, _ configure: (inout Game) -> Void = { _ in }) -> Game {
        var g = Game(id: id, source: source, externalID: externalID, title: title,
                     config: settings.defaultConfig, prefixName: prefix)
        if source == .steam {
            g.coverURL = SteamService.coverURL(externalID)
            g.heroURL = SteamService.heroURL(externalID)
        }
        configure(&g)
        return g
    }

    // MARK: Accounts

    func completeGOGLogin(code: String) async {
        do {
            GOGService.saveSession(try await GOGService.exchange(code: code))
            isGOGLoggedIn = true
            await syncGOG()
        } catch {
            report(error)
        }
    }

    func logoutGOG() {
        GOGService.saveSession(nil)
        isGOGLoggedIn = false
        games.removeAll { $0.source == .gog && !$0.isInstalled }
        saveLibrary()
    }

    // MARK: Wine context

    func context(prefix: String, config: GameConfig) async throws -> WineContext {
        guard rosettaInstalled else { throw LaunchError.rosettaMissing }
        guard let engine = engines.engine(id: config.engineID ?? settings.defaultEngineID) else {
            throw LaunchError.noEngine
        }
        var wineRoot = engine.wineRoot
        if config.graphics == .dxmt {
            wineRoot = try await engines.dxmtVariant(of: engine)
        }
        return WineContext(wineRoot: wineRoot, prefix: Paths.prefixes.appendingPathComponent(prefix),
                           config: config, verboseLogging: settings.verboseWineLogging)
    }

    /// Stops every Wine process in a prefix without needing a fully prepared context.
    private func killPrefix(_ name: String, config: GameConfig) async {
        guard let engine = engines.engine(id: config.engineID ?? settings.defaultEngineID) else { return }
        await WineRunner.kill(WineContext(wineRoot: engine.wineRoot,
                                          prefix: Paths.prefixes.appendingPathComponent(name), config: config))
    }

    private func preparedContext(for game: Game) async throws -> WineContext {
        let ctx = try await context(prefix: game.prefixName, config: game.config)
        try await WineRunner.preparePrefix(ctx)
        if game.config.graphics == .dxvk {
            let dxvk = try await engines.ensureComponent(EngineManager.dxvk)
            try WineRunner.installDXVK(from: dxvk, into: ctx.prefix)
        }
        return ctx
    }

    // MARK: Steam client

    func installSteamClient() {
        startJob("steam-client") { [weak self] in await self?.runSteamClientInstall() }
    }

    private func runSteamClientInstall() async {
        let id = "steam-client"
        setActivity(id, "Steam", "Preparing…", nil)
        defer { endActivity(id) }
        do {
            let ctx = try await context(prefix: SteamService.prefixName, config: settings.defaultConfig)
            try await SteamService.installClient(ctx, progress: progressHandler(id, "Steam", "Downloading installer"))
            try Task.checkCancellation()
            setActivity(id, "Steam", "Starting Steam — sign in to load your library", nil)
            try await openSteam(arguments: [])
        } catch {
            // A cancelled installer may leave Wine processes behind in the Steam prefix.
            if Self.isCancellation(error) { await killPrefix(SteamService.prefixName, config: settings.defaultConfig) }
            report(error)
        }
    }

    /// Opens the Windows Steam client, optionally passing a command (e.g. `steam://install/620`).
    func openSteam(arguments: [String], config: GameConfig? = nil) async throws {
        let config = config ?? steamClientConfig ?? settings.defaultConfig
        var ctx = try await context(prefix: SteamService.prefixName, config: config)
        // Steam games inherit the client's environment, so restart the client if the config differs.
        if let running = steamClientConfig, running != config, processes["steam-client"] != nil {
            await WineRunner.kill(ctx)
            processes["steam-client"] = nil
        }
        ctx.config = config
        try await WineRunner.preparePrefix(ctx)
        if config.graphics == .dxvk {
            try WineRunner.installDXVK(from: try await engines.ensureComponent(EngineManager.dxvk), into: ctx.prefix)
        }
        let log = Paths.logs.appendingPathComponent("steam.log")
        if processes["steam-client"] == nil {
            let p = try WineRunner.launch(ctx, executable: SteamService.steamExe.path,
                                          arguments: SteamService.clientArguments + arguments,
                                          workingDirectory: SteamService.steamRoot, log: log)
            processes["steam-client"] = p
            steamClientConfig = config
            p.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.processes["steam-client"] = nil
                    self?.steamClientConfig = nil
                    await self?.syncSteam()
                }
            }
        } else if !arguments.isEmpty {
            // Forward the command to the running client.
            _ = try WineRunner.launch(ctx, executable: SteamService.steamExe.path, arguments: arguments,
                                      workingDirectory: SteamService.steamRoot, log: log)
        }
    }

    // MARK: Install

    func install(_ game: Game) async {
        switch game.source {
        case .steam:
            do { try await openSteam(arguments: ["steam://install/\(game.externalID)"]) } catch { report(error) }
        case .gog:
            startJob(game.id) { [weak self] in await self?.installGOG(game) }
        case .custom:
            break
        }
    }

    private func installGOG(_ game: Game) async {
        let id = game.id
        setActivity(id, game.title, "Fetching installer…", nil)
        defer { endActivity(id) }
        let dir = Paths.downloads.appendingPathComponent("gog-\(game.externalID)", isDirectory: true)
        var installerStarted = false
        do {
            let files = try await GOGService.installerFiles(gameID: game.externalID)
            let total = files.reduce(0) { $0 + $1.size }
            var done: Int64 = 0
            var downloaded: [URL] = []
            for (n, file) in files.enumerated() {
                let real = try await GOGService.resolveDownlink(file.downlink)
                let base = done
                let part = "Downloading part \(n + 1) of \(files.count)"
                let local = try await Downloader.download(real, into: dir, fileName: real.lastPathComponent.removingPercentEncoding) {
                    [weak self] received, _ in
                    let p = total > 0 ? Double(base + received) / Double(total) : nil
                    let text = "\(part) · \(Format.bytes(base + received)) of \(Format.bytes(total))"
                    Task { @MainActor in self?.updateProgress(id, game.title, text, p) }
                }
                done += file.size
                downloaded.append(local)
            }
            guard let setup = downloaded.first(where: { $0.pathExtension.lowercased() == "exe" }) else {
                throw GOGService.GOGError.noWindowsInstaller
            }

            try Task.checkCancellation()
            setActivity(id, game.title, "Installing…", nil)
            installerStarted = true
            let ctx = try await preparedContext(for: game)
            let folder = Format.safeFolderName(game.title)
            let installDir = ctx.prefix.appendingPathComponent("drive_c/Games/\(folder)", isDirectory: true)
            try await WineRunner.runToCompletion(ctx, executable: setup.path, arguments: [
                "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-", "/NOICONS",
                "/DIR=C:\\Games\\\(folder)",
            ], log: Paths.logs.appendingPathComponent("install-\(game.externalID).log"))

            if !settings.keepInstallers { try? FileManager.default.removeItem(at: dir) }

            guard let task = GOGService.primaryPlayTask(installDir: installDir, gameID: game.externalID) else {
                throw GOGService.GOGError.noExecutable
            }
            let exe = installDir.appendingPathComponent(task.path.replacingOccurrences(of: "\\", with: "/"))
            let work = task.workingDir.map { installDir.appendingPathComponent($0.replacingOccurrences(of: "\\", with: "/")) }
            update(game.id) {
                $0.installState = .installed
                $0.installDirectory = installDir.path
                $0.executablePath = exe.path
                $0.workingDirectory = (work ?? exe.deletingLastPathComponent()).path
                if let args = task.arguments, $0.config.launchArguments.isEmpty { $0.config.launchArguments = args }
                $0.installSizeBytes = Format.directorySize(installDir)
            }
        } catch {
            if Self.isCancellation(error) {
                // Drop partial downloads; a half-run installer means the prefix is unusable too.
                try? FileManager.default.removeItem(at: dir)
                if installerStarted {
                    await killPrefix(game.prefixName, config: game.config)
                    try? FileManager.default.removeItem(at: Paths.prefixes.appendingPathComponent(game.prefixName))
                }
            }
            report(error)
        }
    }

    func uninstall(_ game: Game) async {
        switch game.source {
        case .steam:
            do { try await openSteam(arguments: ["steam://uninstall/\(game.externalID)"]) } catch { report(error) }
        case .gog:
            // Each GOG game owns its prefix, so removing the prefix removes the game completely.
            try? FileManager.default.removeItem(at: Paths.prefixes.appendingPathComponent(game.prefixName))
            update(game.id) {
                $0.installState = .notInstalled
                $0.executablePath = nil
                $0.installDirectory = nil
                $0.installSizeBytes = nil
            }
        case .custom:
            try? FileManager.default.removeItem(at: Paths.prefixes.appendingPathComponent(game.prefixName))
            games.removeAll { $0.id == game.id }
            saveLibrary()
            route = .library
        }
    }

    // MARK: Custom games

    func addCustomGame(executable: URL, title: String) {
        let short = UUID().uuidString.prefix(8).lowercased()
        var g = newGame(id: "custom:\(short)", source: .custom, externalID: String(short),
                        title: title, prefix: "custom-\(short)")
        g.installState = .installed
        g.executablePath = executable.path
        g.workingDirectory = executable.deletingLastPathComponent().path
        g.installDirectory = executable.deletingLastPathComponent().path
        games.append(g)
        saveLibrary()
        Task {
            if let found = await Artwork.searchSteam(title: title) {
                update(g.id) { $0.coverURL = found.cover; $0.heroURL = found.hero }
            }
        }
    }

    // MARK: Play

    func isRunning(_ game: Game) -> Bool { running.contains(game.id) }

    func play(_ game: Game) async {
        guard !running.contains(game.id) else { return }
        let id = game.id
        setActivity(id, game.title, "Preparing…", nil)
        do {
            if game.source == .steam {
                try await openSteam(arguments: ["-applaunch", game.externalID], config: game.config)
                endActivity(id)
                update(id) { $0.lastPlayed = .now }
                return
            }
            guard let exe = game.executablePath else { throw GOGService.GOGError.noExecutable }
            let ctx = try await preparedContext(for: game)
            let log = Paths.logs.appendingPathComponent("\(game.prefixName).log")
            let process = try WineRunner.launch(
                ctx, executable: exe, arguments: [],
                workingDirectory: game.workingDirectory.map { URL(fileURLWithPath: $0) }, log: log)
            endActivity(id)
            running.insert(id)
            processes[id] = process
            let started = Date()
            update(id) { $0.lastPlayed = started }
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.running.remove(id)
                    self.processes[id] = nil
                    self.update(id) { $0.playTimeSeconds += Date().timeIntervalSince(started) }
                }
            }
        } catch {
            endActivity(id)
            report(error)
        }
    }

    func stop(_ game: Game) async {
        guard let ctx = try? await context(prefix: game.prefixName, config: game.config) else { return }
        await WineRunner.kill(ctx)
    }

    func openLog(_ game: Game) {
        let name = game.source == .steam ? "steam.log" : "\(game.prefixName).log"
        let url = Paths.logs.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }

    func revealPrefix(_ game: Game) {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.prefixes.appendingPathComponent(game.prefixName)])
    }
}

enum LaunchError: LocalizedError {
    case rosettaMissing, noEngine
    var errorDescription: String? {
        switch self {
        case .rosettaMissing: "Rosetta 2 is required. Install it from Settings → System."
        case .noEngine: "No Wine engine installed. Download one in Settings → Engines."
        }
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func playTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600, m = (Int(seconds) % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }

    static func safeFolderName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " -_."))
        let cleaned = String(s.unicodeScalars.filter { allowed.contains($0) })
        return cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "Game" : cleaned
    }

    static func directorySize(_ url: URL) -> Int64 {
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
