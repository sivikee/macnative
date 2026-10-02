import Foundation

/// Record of a native Steam install, kept in `data/steam/installs/<appid>.json`.
struct SteamInstallRecord: Codable {
    var appID: UInt32
    var installDir: String
    var manifests: [String: UInt64]     // depot id → manifest gid
    var sizeOnDisk: Int64
    var installedAt: Date
}

/// Downloads a Steam game's depots straight from Steam's CDN (no Steam client), in the spirit of
/// DepotDownloader / GameNative's downloader.
enum SteamInstaller {
    static var root: URL { dir(Paths.root.appendingPathComponent("steam", isDirectory: true)) }
    static var library: URL { dir(root.appendingPathComponent("library/common", isDirectory: true)) }
    static var records: URL { dir(root.appendingPathComponent("installs", isDirectory: true)) }

    private static func dir(_ u: URL) -> URL {
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func installDirectory(_ app: SteamAppInfo) -> URL {
        library.appendingPathComponent(app.installDir, isDirectory: true)
    }

    static func record(_ appID: UInt32) -> SteamInstallRecord? {
        (try? Data(contentsOf: records.appendingPathComponent("\(appID).json")))
            .flatMap { try? JSONDecoder.iso.decode(SteamInstallRecord.self, from: $0) }
    }

    static func removeRecord(_ appID: UInt32) {
        try? FileManager.default.removeItem(at: records.appendingPathComponent("\(appID).json"))
    }

    // MARK: Depot selection

    /// Windows depots the account owns, preferring 64-bit and English, plus owned DLC depots.
    static func selectDepots(_ app: SteamAppInfo, ownership: SteamOwnership, language: String = "english") -> [SteamAppInfo.Depot] {
        let candidates = app.depots.filter { d in
            guard d.manifests["public"] != nil, d.depotFromApp == nil, !d.sharedInstall else { return false }
            guard d.osList.isEmpty || d.osList.contains("windows") else { return false }
            if let lang = d.language, lang != language { return false }
            if let dlc = d.dlcAppID, !ownership.appIDs.contains(dlc) { return false }
            // Same rule as DepotDownloader: a license must list the depot (some list it as an app id).
            return ownership.depotIDs.contains(d.id) || ownership.appIDs.contains(d.id)
        }
        let has64 = candidates.contains { $0.osArch == "64" }
        return candidates.filter { d in
            guard let arch = d.osArch, !arch.isEmpty else { return true }
            return has64 ? arch == "64" : true
        }
    }

    // MARK: Install

    struct Progress {
        var phase: String
        var done: Int64
        var total: Int64
    }

    static func install(_ app: SteamAppInfo, ownership: SteamOwnership, steam: SteamSession,
                        progress: @escaping @Sendable (Progress) -> Void) async throws -> SteamInstallRecord {
        let depots = selectDepots(app, ownership: ownership)
        guard !depots.isEmpty else { throw SteamError(message: "\(app.name) has no Windows content you own") }

        progress(Progress(phase: "Connecting to Steam content servers…", done: 0, total: 0))
        let cdn = try await SteamCDN.discover(steam)

        var manifests: [(DepotManifest, Data)] = []
        var firstError: Error?
        for (n, depot) in depots.enumerated() {
            progress(Progress(phase: "Reading depot \(n + 1) of \(depots.count)…", done: 0, total: 0))
            let gid = depot.manifests["public"]!
            let key: Data
            do {
                key = try await steam.depotKey(depotID: depot.id, appID: app.appID)
            } catch let e as SteamError where e.eresult == 15 {
                // Access denied: an optional depot this account can't use. Skip it.
                firstError = firstError ?? e
                continue
            }
            let code = try await steam.manifestRequestCode(appID: app.appID, depotID: depot.id, gid: gid)
            manifests.append((try await cdn.manifest(depotID: depot.id, gid: gid, requestCode: code, key: key), key))
        }
        if manifests.isEmpty { throw firstError ?? SteamError(message: "\(app.name) has no Windows content you own") }

        let target = installDirectory(app)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let stateURL = target.appendingPathComponent(".macnative-download.json")
        let wanted = Dictionary(uniqueKeysWithValues: manifests.map { (String($0.0.depotID), $0.0.gid) })
        var state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(ResumeState.self, from: $0) }
        if state?.manifests != wanted { state = ResumeState(manifests: wanted, completed: []) }
        let completed = state!.completed

        // Files to fetch, skipping ones finished in an earlier attempt.
        var work: [(file: DepotManifest.File, depot: UInt32, key: Data)] = []
        for (manifest, key) in manifests {
            for file in manifest.files {
                let url = target.appendingPathComponent(file.path)
                if file.isDirectory {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                } else if file.isSymlink, let link = file.linkTarget {
                    try? FileManager.default.removeItem(at: url)
                    try? FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: link)
                } else if !completed.contains(file.path) {
                    work.append((file, manifest.depotID, key))
                }
            }
        }
        let total = Int64(manifests.reduce(0) { $0 + $1.0.totalSize })
        let alreadyDone = total - Int64(work.reduce(0) { $0 + $1.file.size })
        try checkFreeSpace(at: target, needed: total - alreadyDone)

        let tracker = DownloadTracker(state: state!, stateURL: stateURL, done: alreadyDone, total: total, report: progress)
        await tracker.report(force: true)

        // Download chunks with bounded parallelism, writing each straight into its file.
        let writer = FileWriter(root: target)
        let maxInFlight = 12
        try await withThrowingTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var serverHint = 0
            for item in work {
                try await writer.prepare(item.file)
                if item.file.chunks.isEmpty {
                    await writer.finish(item.file.path)
                    await tracker.fileCompleted(item.file.path)
                    continue
                }
                await writer.expect(item.file.path, chunks: item.file.chunks.count)
                for chunk in item.file.chunks {
                    if inFlight >= maxInFlight {
                        try await group.next()
                        inFlight -= 1
                    }
                    serverHint += 1
                    let hint = serverHint
                    group.addTask {
                        let data = try await cdn.chunk(depotID: item.depot, chunk, key: item.key, serverHint: hint)
                        try await writer.write(data, to: item.file.path, at: chunk.offset)
                        await tracker.add(Int64(data.count))
                        if await writer.chunkDone(item.file.path) {
                            await tracker.fileCompleted(item.file.path)
                        }
                    }
                    inFlight += 1
                }
            }
            try await group.waitForAll()
        }
        await writer.closeAll()
        await tracker.save()
        try? FileManager.default.removeItem(at: stateURL)

        let record = SteamInstallRecord(appID: app.appID, installDir: target.path, manifests: wanted,
                                        sizeOnDisk: total, installedAt: .now)
        try JSONEncoder.pretty.encode(record).write(to: records.appendingPathComponent("\(app.appID).json"))
        return record
    }

    static func uninstall(_ appID: UInt32) {
        if let r = record(appID) { try? FileManager.default.removeItem(atPath: r.installDir) }
        removeRecord(appID)
    }

    private static func checkFreeSpace(at url: URL, needed: Int64) throws {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < needed + 512 << 20 {
            throw SteamError(message: "Not enough disk space: needs \(Format.bytes(needed)), \(Format.bytes(free)) free")
        }
    }
}

/// Which files of which manifests are already on disk, for resuming interrupted downloads.
private struct ResumeState: Codable, Sendable {
    var manifests: [String: UInt64]
    var completed: Set<String>
}

/// Tracks bytes and finished files, throttles progress callbacks and persists resume state.
private actor DownloadTracker {
    private var state: ResumeState
    private let stateURL: URL
    private var done: Int64
    private let total: Int64
    private let reportFn: @Sendable (SteamInstaller.Progress) -> Void
    private var lastReport = Date.distantPast
    private var lastSave = Date()

    init(state: ResumeState, stateURL: URL, done: Int64, total: Int64,
         report: @escaping @Sendable (SteamInstaller.Progress) -> Void) {
        self.state = state
        self.stateURL = stateURL
        self.done = done
        self.total = total
        reportFn = report
    }

    func add(_ bytes: Int64) async {
        done += bytes
        await report(force: false)
    }

    func report(force: Bool) async {
        guard force || Date().timeIntervalSince(lastReport) > 0.25 else { return }
        lastReport = Date()
        reportFn(SteamInstaller.Progress(phase: "Downloading", done: done, total: total))
    }

    func fileCompleted(_ path: String) async {
        state.completed.insert(path)
        if Date().timeIntervalSince(lastSave) > 3 { await save() }
    }

    func save() async {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
        lastSave = Date()
    }
}

/// Owns open file descriptors so concurrent chunk writes land at the right offsets.
private actor FileWriter {
    let root: URL
    private var fds: [String: Int32] = [:]
    private var remaining: [String: Int] = [:]

    init(root: URL) { self.root = root }

    func prepare(_ file: DepotManifest.File) throws {
        let url = root.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw SteamError(message: "Can't write \(file.path)") }
        ftruncate(fd, off_t(file.size))
        fds[file.path] = fd
    }

    func expect(_ path: String, chunks: Int) { remaining[path] = chunks }

    func write(_ data: Data, to path: String, at offset: UInt64) throws {
        guard let fd = fds[path] else { return }
        let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
        guard written == data.count else { throw SteamError(message: "Disk write failed for \(path)") }
    }

    /// Returns true when the file's last chunk has been written.
    func chunkDone(_ path: String) -> Bool {
        remaining[path, default: 1] -= 1
        guard remaining[path] == 0 else { return false }
        finish(path)
        return true
    }

    func finish(_ path: String) {
        if let fd = fds.removeValue(forKey: path) { close(fd) }
        remaining[path] = nil
    }

    func closeAll() {
        for fd in fds.values { close(fd) }
        fds = [:]
    }
}
