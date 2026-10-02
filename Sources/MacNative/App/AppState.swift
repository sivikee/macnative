import Foundation
import Observation
import AppKit

struct AppSettings: Codable {
    var defaultEngineID: String?
    var defaultConfig = GameConfig.default
    var verboseWineLogging = false
    var keepInstallers = false
    var hasCompletedSetup = false
    /// Use the D3DMetal imported from Apple instead of the one bundled with the GPTK engine.
    var useImportedD3DMetal = true
}

extension AppSettings {
    /// Lenient decoding so new settings never reset existing ones.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        defaultEngineID = try c.decodeIfPresent(String.self, forKey: .defaultEngineID)
        defaultConfig = try c.decodeIfPresent(GameConfig.self, forKey: .defaultConfig) ?? d.defaultConfig
        verboseWineLogging = try c.decodeIfPresent(Bool.self, forKey: .verboseWineLogging) ?? d.verboseWineLogging
        keepInstallers = try c.decodeIfPresent(Bool.self, forKey: .keepInstallers) ?? d.keepInstallers
        hasCompletedSetup = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedSetup) ?? d.hasCompletedSetup
        useImportedD3DMetal = try c.decodeIfPresent(Bool.self, forKey: .useImportedD3DMetal) ?? d.useImportedD3DMetal
    }
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
    let steam = SteamStore()

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
    var showSteamLogin = false
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
        steam.onLibraryChanged = { [weak self] in self?.mergeSteamLibrary() }
        mergeSteamLibrary()
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
        if steam.isOnline { await steam.sync() } else { await steam.resume() }
        await syncGOG()
    }

    /// Merges the native Steam library (owned Windows games) into `games`.
    func mergeSteamLibrary() {
        let owned = steam.ownedGames
        let ids = Set(owned.map { "steam:\($0.appID)" })
        for info in owned {
            let id = "steam:\(info.appID)"
            if let i = games.firstIndex(where: { $0.id == id }) {
                games[i].title = info.name
                games[i].developer = info.developer ?? games[i].developer
                games[i].releaseYear = info.releaseYear ?? games[i].releaseYear
                // Games added by the old client-scan mode shared one prefix; native games get their own.
                if games[i].prefixName == SteamService.prefixName { games[i].prefixName = "steam-\(info.appID)" }
            } else {
                games.append(newGame(id: id, source: .steam, externalID: String(info.appID), title: info.name,
                                     prefix: "steam-\(info.appID)") {
                    $0.developer = info.developer
                    $0.releaseYear = info.releaseYear
                })
            }
        }
        // Keep installed games even if ownership can't be confirmed right now (offline, family sharing…).
        games.removeAll { $0.source == .steam && !ids.contains($0.id) && !$0.isInstalled && !$0.config.useSteamClient }
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
        var wineRoot: URL
        if config.graphics == .d3dmetal {
            // D3DMetal needs Apple's GPTK Wine, whatever engine the game is otherwise set to.
            guard let gptk = engines.gptkEngine else { throw LaunchError.noD3DMetalEngine }
            if settings.useImportedD3DMetal, let d3d = engines.d3dmetalImport {
                wineRoot = try await engines.d3dmetalVariant(of: gptk, using: d3d)
            } else {
                wineRoot = gptk.wineRoot
            }
        } else {
            guard let engine = engines.engine(id: config.engineID ?? settings.defaultEngineID) else {
                throw LaunchError.noEngine
            }
            wineRoot = engine.wineRoot
            if config.graphics == .dxmt {
                wineRoot = try await engines.dxmtVariant(of: engine)
            }
        }
        return WineContext(wineRoot: wineRoot, prefix: Paths.prefixes.appendingPathComponent(prefix),
                           config: config, verboseLogging: settings.verboseWineLogging)
    }

    /// Downloads the GPTK engine the first time a D3DMetal game launches, reporting into `activityID`.
    private func ensureD3DMetalEngine(_ config: GameConfig, activityID: String, title: String) async throws {
        guard config.graphics == .d3dmetal, engines.gptkEngine == nil else { return }
        let release = engines.gptkRelease
        setActivity(activityID, title, "Downloading DirectX 12 support…", 0)
        try await engines.install(release, progress: progressHandler(activityID, title, "Downloading DirectX 12 support"))
        setActivity(activityID, title, "Preparing…", nil)
    }

    /// Human-readable engine for a config, as shown on the game page.
    func engineDescription(for config: GameConfig) -> String {
        if config.graphics == .d3dmetal {
            guard let gptk = engines.gptkEngine else { return "GPTK (downloads on first launch)" }
            if settings.useImportedD3DMetal, let d3d = engines.d3dmetalImport { return "\(gptk.name) · D3DMetal \(d3d.version)" }
            return gptk.name
        }
        return engines.engine(id: config.engineID ?? settings.defaultEngineID)?.name ?? "None installed"
    }

    func installD3DMetalEngine() {
        let release = engines.gptkRelease
        startJob("engine:\(release.id)") { [weak self] in await self?.runEngineInstall(release) }
    }

    func importD3DMetal(from url: URL) {
        startJob("d3dmetal-import") { [weak self] in
            guard let self else { return }
            self.setActivity("d3dmetal-import", "D3DMetal", "Importing from \(url.lastPathComponent)…", nil)
            defer { self.endActivity("d3dmetal-import") }
            do {
                try await self.engines.importD3DMetal(from: url)
                self.settings.useImportedD3DMetal = true
            } catch {
                self.report(error)
            }
        }
    }

    /// Stops every Wine process in a prefix without needing a fully prepared context.
    private func killPrefix(_ name: String, config: GameConfig) async {
        let engine = config.graphics == .d3dmetal ? engines.gptkEngine
            : engines.engine(id: config.engineID ?? settings.defaultEngineID)
        guard let engine else { return }
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
        case .steam where game.config.useSteamClient:
            do { try await openSteam(arguments: ["steam://install/\(game.externalID)"], config: game.config) } catch { report(error) }
        case .steam:
            toast = "Native Steam downloads are being built right now — coming in the next update."
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
                let name = real.lastPathComponent.removingPercentEncoding ?? real.lastPathComponent
                // Reuse parts kept from an earlier attempt (GOG's listed sizes are slightly rounded down).
                let existing = dir.appendingPathComponent(name)
                if let size = (try? existing.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, Int64(size) >= file.size {
                    done += file.size
                    downloaded.append(existing)
                    continue
                }
                let local = try await Downloader.download(real, into: dir, fileName: name) {
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
            let folder = Format.safeFolderName(game.title)
            let installDir = Paths.prefixes.appendingPathComponent("\(game.prefixName)/drive_c/Games/\(folder)", isDirectory: true)

            var task: GOGService.PlayTask?
            do {
                let ctx = try await preparedContext(for: game)
                try await runGOGInstaller(ctx, setup: setup, folder: folder, game: game)
                task = GOGService.primaryPlayTask(installDir: installDir, gameID: game.externalID)
                if task == nil { throw GOGService.GOGError.noExecutable }
            } catch where !Self.isCancellation(error) {
                // Some GOG installers (32-bit Inno Setup with custom UI) crash under new Wine on macOS.
                // Retry once in a fresh prefix with the Game Porting Toolkit Wine, which handles them.
                // The game itself still runs on the engine chosen in its settings.
                setActivity(id, game.title, "Installer failed, retrying with the compatibility engine…", nil)
                await killPrefix(game.prefixName, config: game.config)
                try? FileManager.default.removeItem(at: Paths.prefixes.appendingPathComponent(game.prefixName))
                var compat = game.config
                compat.graphics = .d3dmetal
                try await ensureD3DMetalEngine(compat, activityID: id, title: game.title)
                setActivity(id, game.title, "Installing (compatibility mode)…", nil)
                let ctx = try await context(prefix: game.prefixName, config: compat)
                try await WineRunner.preparePrefix(ctx)
                try await runGOGInstaller(ctx, setup: setup, folder: folder, game: game)
                task = GOGService.primaryPlayTask(installDir: installDir, gameID: game.externalID)
            }

            if !settings.keepInstallers { try? FileManager.default.removeItem(at: dir) }

            guard let task else { throw GOGService.GOGError.noExecutable }
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

    /// Runs a GOG Inno Setup installer silently, keeping both our log and Inno's own log.
    private func runGOGInstaller(_ ctx: WineContext, setup: URL, folder: String, game: Game) async throws {
        let innoLog = ctx.prefix.appendingPathComponent("drive_c/macnative-install.log")
        defer {
            let dest = Paths.logs.appendingPathComponent("install-\(game.externalID)-setup.log")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: innoLog, to: dest)
        }
        try await WineRunner.runToCompletion(ctx, executable: setup.path, arguments: [
            "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-", "/NOICONS",
            "/DIR=C:\\Games\\\(folder)", "/LOG=C:\\macnative-install.log",
        ], log: Paths.logs.appendingPathComponent("install-\(game.externalID).log"))
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

    // MARK: Erase

    /// Stops everything and deletes all games, prefixes, engines, downloads, accounts and settings.
    func eraseEverything() async {
        setActivity("erase", "Erasing", "Stopping games and downloads…", nil)
        defer { endActivity("erase") }

        for job in jobs.values { job.cancel() }
        for p in processes.values where p.isRunning { p.terminate() }
        // Shut down each prefix's wineserver while the engines still exist.
        let prefixes = (try? FileManager.default.contentsOfDirectory(atPath: Paths.prefixes.path)) ?? []
        for name in prefixes where !name.hasPrefix(".") {
            await killPrefix(name, config: settings.defaultConfig)
        }

        setActivity("erase", "Erasing", "Deleting files…", nil)
        let items = Paths.ownedItems
        await Task.detached {
            for url in items { try? FileManager.default.removeItem(at: url) }
        }.value
        URLCache.shared.removeAllCachedResponses()

        processes = [:]
        running = []
        steamClientConfig = nil
        games = []
        engines.reloadInstalled()
        isGOGLoggedIn = false
        route = .library
        filter = .all
        focusedIndex = 0
        settings = AppSettings()
        showSetup = true
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

    /// Prepares (possibly downloading DirectX 12 support first) and launches a game as a cancellable job.
    func play(_ game: Game) {
        guard !running.contains(game.id) else { return }
        startJob(game.id) { [weak self] in await self?.runPlay(game) }
    }

    private func runPlay(_ game: Game) async {
        let id = game.id
        setActivity(id, game.title, "Preparing…", nil)
        do {
            try await ensureD3DMetalEngine(game.config, activityID: id, title: game.title)
            if game.source == .steam, game.config.useSteamClient {
                try await openSteam(arguments: ["-applaunch", game.externalID], config: game.config)
                endActivity(id)
                update(id) { $0.lastPlayed = .now }
                return
            }
            guard let exe = game.executablePath else { throw GOGService.GOGError.noExecutable }
            let ctx = try await preparedContext(for: game)
            try Task.checkCancellation()
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

    /// Opens the newest log for this game (run, install, or installer's own log).
    func openLog(_ game: Game) {
        let names = game.source == .steam
            ? ["steam.log", "\(game.prefixName).log"]
            : ["\(game.prefixName).log", "install-\(game.externalID).log", "install-\(game.externalID)-setup.log"]
        let newest = names.map { Paths.logs.appendingPathComponent($0) }
            .compactMap { url -> (URL, Date)? in
                guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { return nil }
                return (url, d)
            }
            .max { $0.1 < $1.1 }?.0
        if let newest {
            // Open in TextEdit explicitly: .log files may have no default app, which silently does nothing.
            let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            NSWorkspace.shared.open([newest], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            toast = "No log yet for \(game.title). Logs appear after the first install or launch."
            NSWorkspace.shared.open(Paths.logs)
        }
    }

    func revealPrefix(_ game: Game) {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.prefixes.appendingPathComponent(game.prefixName)])
    }
}

enum LaunchError: LocalizedError {
    case rosettaMissing, noEngine, noD3DMetalEngine
    var errorDescription: String? {
        switch self {
        case .noD3DMetalEngine: "DirectX 12 support isn't downloaded yet. Get it in Settings → Engines."
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
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
