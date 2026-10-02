import Foundation

/// What MacNative needs to know about a Steam app, distilled from PICS app info.
struct SteamAppInfo: Codable, Hashable {
    struct Depot: Codable, Hashable {
        var id: UInt32
        var manifests: [String: UInt64]     // branch → manifest gid
        var encryptedBranches: [String]
        var maxSize: Int64?
        var osList: [String]
        var osArch: String?
        var language: String?
        var dlcAppID: UInt32?
        var depotFromApp: UInt32?
        var sharedInstall: Bool
    }

    struct LaunchOption: Codable, Hashable {
        var executable: String
        var arguments: String?
        var workingDir: String?
        var osList: [String]
        var type: String?
        var betaKey: String?
        var description: String?
    }

    var appID: UInt32
    var name: String
    var type: String
    var osList: [String]
    var installDir: String
    var developer: String?
    var releaseYear: Int?
    var depots: [Depot]
    var launch: [LaunchOption]
    var dlcAppIDs: [UInt32]
    var parentAppID: UInt32?

    var isGame: Bool { type.lowercased() == "game" }
    var isDLC: Bool { type.lowercased() == "dlc" }
    var runsOnWindows: Bool { osList.isEmpty || osList.contains("windows") }

    /// Launch entries usable on Windows (no beta-only entries), in Steam's order.
    var windowsLaunchOptions: [LaunchOption] {
        launch.filter { ($0.osList.isEmpty || $0.osList.contains("windows")) && $0.betaKey == nil }
    }

    /// The entry a player most likely means by "Play": one whose file exists, a default type,
    /// and not an editor/server/tool. Ties keep Steam's order.
    func bestLaunchOption(installDir: URL) -> LaunchOption? {
        func score(_ o: LaunchOption) -> Int {
            var s = 0
            let exe = installDir.appendingPathComponent(o.executable.replacingOccurrences(of: "\\", with: "/"))
            if FileManager.default.fileExists(atPath: exe.path) { s += 100 }
            if o.type == nil || o.type == "default" || o.type == "none" { s += 10 }
            if o.osList.contains("windows") { s += 2 }
            let text = "\(o.description ?? "") \(o.executable)".lowercased()
            if ["editor", "server", "tool", "benchmark", "config", "safe mode", "sdk", "modded"]
                .contains(where: text.contains) { s -= 50 }
            return s
        }
        let options = windowsLaunchOptions
        return options.enumerated().max { a, b in
            let (sa, sb) = (score(a.element), score(b.element))
            return sa == sb ? a.offset > b.offset : sa < sb
        }?.element
    }

    init?(appID: UInt32, kv: VDF.Node) {
        guard let common = kv["common"], let name = common["name"]?.string else { return nil }
        self.appID = appID
        self.name = name
        type = common["type"]?.string ?? ""
        osList = Self.list(common["oslist"]?.string)
        parentAppID = common["parent"]?.string.flatMap(UInt32.init)
        developer = kv["extended"]?["developer"]?.string
        if let t = common["steam_release_date"]?.string.flatMap(TimeInterval.init) {
            releaseYear = Calendar.current.component(.year, from: Date(timeIntervalSince1970: t))
        }
        installDir = kv["config"]?["installdir"]?.string ?? Format.safeFolderName(name)
        dlcAppIDs = (kv["extended"]?["listofdlc"]?.string ?? "").split(separator: ",")
            .compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }

        launch = (kv["config"]?["launch"]?.children ?? []).compactMap { _, l in
            guard let exe = l["executable"]?.string, !exe.isEmpty else { return nil }
            return LaunchOption(executable: exe, arguments: l["arguments"]?.string,
                                workingDir: l["workingdir"]?.string,
                                osList: Self.list(l["config"]?["oslist"]?.string),
                                type: l["type"]?.string, betaKey: l["config"]?["betakey"]?.string,
                                description: l["description"]?.string)
        }

        depots = (kv["depots"]?.children ?? []).compactMap { key, d in
            guard let id = UInt32(key) else { return nil }   // skips "branches", "baselanguages", …
            var manifests: [String: UInt64] = [:]
            for (branch, m) in d["manifests"]?.children ?? [] {
                // Newer format: { "gid": "…", "size": "…" }; older: "branch" "gid".
                if let gid = (m["gid"]?.string ?? m.string).flatMap(UInt64.init) { manifests[branch] = gid }
            }
            let cfg = d["config"]
            return Depot(id: id, manifests: manifests,
                         encryptedBranches: (d["encryptedmanifests"]?.children ?? []).map(\.0),
                         maxSize: d["maxsize"]?.string.flatMap(Int64.init),
                         osList: Self.list(cfg?["oslist"]?.string), osArch: cfg?["osarch"]?.string,
                         language: cfg?["language"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                         dlcAppID: d["dlcappid"]?.string.flatMap(UInt32.init),
                         depotFromApp: d["depotfromapp"]?.string.flatMap(UInt32.init),
                         sharedInstall: d["sharedinstall"]?.string == "1")
        }
    }

    private static func list(_ s: String?) -> [String] {
        (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
}

/// Everything the account owns, resolved through PICS.
struct SteamOwnership: Codable {
    var appIDs: Set<UInt32>
    var depotIDs: Set<UInt32>
    var appTokens: [UInt32: UInt64]
}

extension SteamSession {
    /// Resolves licenses → packages → owned app & depot ids.
    func fetchOwnership() async throws -> SteamOwnership {
        let licenses = await waitForLicenses()
        guard !licenses.isEmpty else { return SteamOwnership(appIDs: [], depotIDs: [], appTokens: [:]) }

        var apps = Set<UInt32>(), depots = Set<UInt32>()
        for chunk in licenses.chunked(200) {
            let packets = try await connection.job(.clientPICSProductInfoRequest, isFinal: Self.picsFinal) { w in
                for l in chunk {
                    w.message(1) { p in
                        p.uint32(1, l.packageID)
                        if l.accessToken != 0 { p.uint64(2, l.accessToken) }
                    }
                }
                w.bool(3, false)
            }
            for p in packets {
                guard let body = try? ProtoMessage(p.body) else { continue }
                for pkg in body.messages(3) {
                    guard let buffer = pkg.bytes(5), buffer.count > 4,
                          let kv = BinaryVDF.parse(buffer.dropFirst(4)),     // first 4 bytes: package id
                          let root = kv.children.first?.1 else { continue }
                    for (_, v) in root["appids"]?.children ?? [] { if let id = v.string.flatMap(UInt32.init) { apps.insert(id) } }
                    for (_, v) in root["depotids"]?.children ?? [] { if let id = v.string.flatMap(UInt32.init) { depots.insert(id) } }
                }
            }
        }

        // App access tokens are needed to read info for some owned apps.
        var tokens: [UInt32: UInt64] = [:]
        for chunk in Array(apps).chunked(500) {
            let packets = try await connection.job(.clientPICSAccessTokenRequest) { w in
                for id in chunk { w.uint32(2, id) }
            }
            for p in packets {
                guard let body = try? ProtoMessage(p.body) else { continue }
                for t in body.messages(3) {
                    if let id = t.uint32(1), let tok = t.uint64(2), tok != 0 { tokens[id] = tok }
                }
            }
        }
        return SteamOwnership(appIDs: apps, depotIDs: depots, appTokens: tokens)
    }

    /// Fetches PICS app info for the given apps.
    func fetchAppInfo(_ appIDs: [UInt32], tokens: [UInt32: UInt64]) async throws -> [SteamAppInfo] {
        var result: [SteamAppInfo] = []
        for chunk in appIDs.chunked(150) {
            let packets = try await connection.job(.clientPICSProductInfoRequest, isFinal: Self.picsFinal) { w in
                for id in chunk {
                    w.message(2) { a in
                        a.uint32(1, id)
                        if let t = tokens[id] { a.uint64(2, t) }
                    }
                }
                w.bool(3, false)
            }
            for p in packets {
                guard let body = try? ProtoMessage(p.body) else { continue }
                let httpHost = body.string(8)
                for app in body.messages(1) {
                    guard let id = app.uint32(1) else { continue }
                    var buffer = app.bytes(5)
                    if (buffer?.isEmpty ?? true), let host = httpHost, let sha = app.bytes(4) {
                        buffer = await Self.fetchAppInfoOverHTTP(host: host, appID: id, sha: sha)
                    }
                    guard let buffer, let text = String(data: buffer.prefix { $0 != 0 }, encoding: .utf8),
                          let kv = VDF.parse(text)["appinfo"],
                          let info = SteamAppInfo(appID: id, kv: kv) else { continue }
                    result.append(info)
                }
            }
        }
        return result
    }

    private static func fetchAppInfoOverHTTP(host: String, appID: UInt32, sha: Data) async -> Data? {
        guard let url = URL(string: "https://\(host)/appinfo/\(appID)/sha/\(sha.hexString).txt.gz"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return Gzip.decompress(data) ?? data
    }

    private static let picsFinal: (SteamConnection.Packet) -> Bool = { p in
        !((try? ProtoMessage(p.body))?.bool(6) ?? false)   // response_pending
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
