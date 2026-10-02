import Foundation

/// Steam support for v1 runs the official Windows Steam client inside a dedicated prefix.
/// MacNative reads the client's files to build the library and asks it to install/launch games,
/// which keeps Steam DRM, cloud saves and achievements working without reimplementing the protocol.
enum SteamService {
    static let prefixName = "steam"
    static let installerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
    /// Chromium-based UI flags that keep steamwebhelper stable under Wine on macOS.
    static let clientArguments = ["-cef-disable-gpu", "-cef-disable-gpu-compositing", "-cef-in-process-gpu", "-no-cef-sandbox"]

    static var prefix: URL { Paths.prefixes.appendingPathComponent(prefixName, isDirectory: true) }
    static var steamRoot: URL { prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true) }
    static var steamExe: URL { steamRoot.appendingPathComponent("steam.exe") }
    static var isClientInstalled: Bool { FileManager.default.fileExists(atPath: steamExe.path) }

    static func installClient(_ ctx: WineContext, progress: @escaping Downloader.Progress) async throws {
        try await WineRunner.preparePrefix(ctx)
        let setup = try await Downloader.download(installerURL, into: Paths.downloads, fileName: "SteamSetup.exe", progress: progress)
        defer { try? FileManager.default.removeItem(at: setup) }
        try await WineRunner.runToCompletion(ctx, executable: setup.path, arguments: ["/S"])
    }

    struct LocalApp {
        var appID: String
        var name: String?
        var installed: Bool
        var installDir: URL?
        var sizeOnDisk: Int64?
    }

    /// Lists games the Steam client knows about: installed ones from `appmanifest_*.acf`, plus owned
    /// ones from the client's library artwork cache (populated after logging in to the client once).
    static func scanLibrary() -> [LocalApp] {
        guard isClientInstalled else { return [] }
        var apps: [String: LocalApp] = [:]

        for library in libraryFolders() {
            let steamapps = library.appendingPathComponent("steamapps")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: steamapps.path)) ?? []
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: steamapps.appendingPathComponent(file), encoding: .utf8),
                      let state = VDF.parse(text)["AppState"],
                      let appID = state["appid"]?.string else { continue }
                let flags = Int(state["StateFlags"]?.string ?? "") ?? 0
                let dir = state["installdir"]?.string.map { steamapps.appendingPathComponent("common/\($0)") }
                apps[appID] = LocalApp(appID: appID, name: state["name"]?.string,
                                       installed: flags & 4 != 0, installDir: dir,
                                       sizeOnDisk: Int64(state["SizeOnDisk"]?.string ?? ""))
            }
        }

        let cache = steamRoot.appendingPathComponent("appcache/librarycache")
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [] {
            // Newer clients use one folder per app; older ones use "<appid>_library_600x900.jpg".
            let id = String(entry.prefix { $0.isNumber })
            guard !id.isEmpty, apps[id] == nil, id != "7" else { continue }
            apps[id] = LocalApp(appID: id, name: nil, installed: false)
        }
        return Array(apps.values)
    }

    private static func libraryFolders() -> [URL] {
        var result = [steamRoot]
        let file = steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for (_, folder) in VDF.parse(text)["libraryfolders"]?.children ?? [] {
                if let path = folder["path"]?.string, let url = unixPath(forWindowsPath: path),
                   !result.contains(url) {
                    result.append(url)
                }
            }
        }
        return result
    }

    /// Maps `C:\Foo\Bar` to the prefix's `drive_c/Foo/Bar`.
    static func unixPath(forWindowsPath path: String) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\\\", with: "\\")
        guard normalized.count > 2, normalized.dropFirst().hasPrefix(":") else { return nil }
        let drive = normalized.prefix(1).lowercased()
        let rest = normalized.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
        return prefix.appendingPathComponent("drive_\(drive)/\(rest)", isDirectory: true)
    }

    static func coverURL(_ appID: String) -> URL {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_600x900_2x.jpg")!
    }

    static func heroURL(_ appID: String) -> URL {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_hero.jpg")!
    }

    struct StoreDetails { var name: String; var isGame: Bool; var developer: String?; var year: Int?; var header: URL? }

    /// Public store metadata (no login needed). Returns nil for delisted/region-locked apps.
    static func storeDetails(_ appID: String) async -> StoreDetails? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=english"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[appID] as? [String: Any], entry["success"] as? Bool == true,
              let d = entry["data"] as? [String: Any], let name = d["name"] as? String
        else { return nil }
        let date = (d["release_date"] as? [String: Any])?["date"] as? String
        let year = date.flatMap { s in s.split(separator: " ").last.flatMap { Int($0) } }
        return StoreDetails(name: name, isGame: (d["type"] as? String) == "game",
                            developer: (d["developers"] as? [String])?.first, year: year,
                            header: (d["header_image"] as? String).flatMap(URL.init(string:)))
    }
}
