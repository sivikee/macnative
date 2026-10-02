import Foundation
import Observation

/// A downloadable Wine build. MacNative uses Gcenx's upstream macOS builds
/// (https://github.com/Gcenx/macOS_Wine_builds) which bundle MoltenVK, SDL2 and wine-mono.
struct EngineRelease: Identifiable, Hashable, Codable {
    var id: String          // e.g. "wine-staging-11.18"
    var name: String        // e.g. "Wine Staging 11.18"
    var version: String
    var flavor: String      // "staging" | "devel"
    var url: URL
    var sizeBytes: Int64
}

struct InstalledEngine: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var version: String
    var installedAt: Date

    var directory: URL { Paths.engines.appendingPathComponent(id, isDirectory: true) }
    /// Root of the Wine install (`bin/`, `lib/`, `share/`).
    var wineRoot: URL { directory.appendingPathComponent("wine", isDirectory: true) }
}

/// Translation layers that are dropped into an engine or prefix on demand.
struct ComponentRelease: Identifiable, Hashable, Codable {
    var id: String          // "dxvk" | "dxmt"
    var name: String
    var version: String
    var url: URL
}

@MainActor
@Observable
final class EngineManager {
    private(set) var installed: [InstalledEngine] = []
    private(set) var available: [EngineRelease] = []
    private(set) var isLoadingCatalog = false
    var catalogError: String?

    static let dxvk = ComponentRelease(
        id: "dxvk", name: "DXVK-macOS (async)", version: "1.10.3-20230507-repack",
        url: URL(string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz")!)

    static let dxmt = ComponentRelease(
        id: "dxmt", name: "DXMT", version: "v0.80",
        url: URL(string: "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz")!)

    /// Known-good fallback if the GitHub API is unreachable or rate limited.
    static let fallbackEngine = EngineRelease(
        id: "wine-staging-11.18", name: "Wine Staging 11.18", version: "11.18", flavor: "staging",
        url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-staging-11.18-osx64.tar.xz")!,
        sizeBytes: 193_105_336)

    init() { reloadInstalled() }

    func reloadInstalled() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Paths.engines, includingPropertiesForKeys: nil)) ?? []
        installed = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("engine.json")) else { return nil }
            return try? JSONDecoder.iso.decode(InstalledEngine.self, from: data)
        }
        .filter { fm.isExecutableFile(atPath: $0.wineRoot.appendingPathComponent("bin/wine").path) }
        .sorted { $0.installedAt > $1.installedAt }
    }

    func engine(id: String?) -> InstalledEngine? {
        if let id, let e = installed.first(where: { $0.id == id }) { return e }
        return installed.first
    }

    func isComponentInstalled(_ c: ComponentRelease) -> Bool {
        FileManager.default.fileExists(atPath: componentDirectory(c).path)
    }

    func componentDirectory(_ c: ComponentRelease) -> URL {
        Paths.components.appendingPathComponent("\(c.id)/\(c.version)", isDirectory: true)
    }

    // MARK: Catalog

    func refreshCatalog() async {
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            let url = URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases?per_page=6")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            available = releases.flatMap { r in
                r.assets.compactMap { a -> EngineRelease? in
                    guard a.name.hasSuffix("-osx64.tar.xz") else { return nil }
                    let flavor = a.name.hasPrefix("wine-staging") ? "staging"
                        : a.name.hasPrefix("wine-devel") ? "devel" : nil
                    guard let flavor else { return nil }
                    return EngineRelease(
                        id: "wine-\(flavor)-\(r.tag_name)", name: "Wine \(flavor.capitalized) \(r.tag_name)",
                        version: r.tag_name, flavor: flavor, url: a.browser_download_url, sizeBytes: a.size)
                }
            }
            catalogError = nil
        } catch {
            catalogError = "Couldn't reach GitHub, showing the bundled default."
        }
        if available.isEmpty { available = [Self.fallbackEngine] }
    }

    var recommended: EngineRelease {
        available.first(where: { $0.flavor == "staging" }) ?? Self.fallbackEngine
    }

    // MARK: Install

    func install(_ release: EngineRelease, progress: @escaping Downloader.Progress) async throws {
        let archive = try await Downloader.download(
            release.url, into: Paths.downloads, fileName: release.url.lastPathComponent, progress: progress)
        defer { try? FileManager.default.removeItem(at: archive) }

        let target = Paths.engines.appendingPathComponent(release.id, isDirectory: true)
        let staging = Paths.engines.appendingPathComponent(".\(release.id)-extract", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.removeItem(at: target)
        // Archive layout: "Wine Staging.app/Contents/Resources/wine/{bin,lib,share}". Only that
        // subtree is wanted (the .app's own launcher would collide with the stripped `wine` folder).
        try await Shell.extract(archive, to: staging, stripComponents: 3, include: "*/Contents/Resources/wine/*")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging.appendingPathComponent("wine"),
                                         to: target.appendingPathComponent("wine"))
        try? FileManager.default.removeItem(at: staging)
        // Downloaded files are quarantined; clear it so Gatekeeper doesn't block every dylib.
        _ = try? await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path])

        let engine = InstalledEngine(id: release.id, name: release.name, version: release.version, installedAt: .now)
        try JSONEncoder.pretty.encode(engine).write(to: target.appendingPathComponent("engine.json"))
        reloadInstalled()
    }

    func uninstall(_ engine: InstalledEngine) throws {
        try FileManager.default.removeItem(at: engine.directory)
        reloadInstalled()
    }

    func ensureComponent(_ c: ComponentRelease, progress: Downloader.Progress? = nil) async throws -> URL {
        let dir = componentDirectory(c)
        if FileManager.default.fileExists(atPath: dir.path) { return dir }
        let archive = try await Downloader.download(c.url, into: Paths.downloads, progress: progress)
        defer { try? FileManager.default.removeItem(at: archive) }
        let tmp = dir.deletingLastPathComponent().appendingPathComponent(".extract-\(c.version)")
        try? FileManager.default.removeItem(at: tmp)
        try await Shell.extract(archive, to: tmp, stripComponents: 1)
        try FileManager.default.moveItem(at: tmp, to: dir)
        return dir
    }

    /// DXMT ships *builtin* DLLs plus a unix-side `winemetal.so`, which must live inside Wine's own
    /// lib folders. Rather than modifying the engine, we make an APFS clone of it (instant, no extra
    /// disk space) and add DXMT to the clone.
    func dxmtVariant(of engine: InstalledEngine) async throws -> URL {
        let dxmt = try await ensureComponent(Self.dxmt)
        let variant = engine.directory.appendingPathComponent("variants/dxmt-\(Self.dxmt.version)", isDirectory: true)
        let wine = variant.appendingPathComponent("wine")
        if FileManager.default.fileExists(atPath: wine.appendingPathComponent("bin/wine").path) { return wine }

        try? FileManager.default.removeItem(at: variant)
        try FileManager.default.createDirectory(at: variant, withIntermediateDirectories: true)
        try await Shell.run("/bin/cp", ["-cR", engine.wineRoot.path, wine.path])
        for arch in ["x86_64-windows", "i386-windows", "x86_64-unix"] {
            let src = dxmt.appendingPathComponent(arch)
            let dst = wine.appendingPathComponent("lib/wine/\(arch)")
            for file in (try? FileManager.default.contentsOfDirectory(atPath: src.path)) ?? [] {
                let to = dst.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: to)
                try FileManager.default.copyItem(at: src.appendingPathComponent(file), to: to)
            }
        }
        return wine
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable { var name: String; var size: Int64; var browser_download_url: URL }
    var tag_name: String
    var assets: [Asset]
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
