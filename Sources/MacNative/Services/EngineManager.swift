import Foundation
import Observation

/// A downloadable Wine build. MacNative uses Gcenx's upstream macOS builds
/// (https://github.com/Gcenx/macOS_Wine_builds) which bundle MoltenVK, SDL2 and wine-mono.
struct EngineRelease: Identifiable, Hashable, Codable {
    var id: String          // e.g. "wine-staging-11.18"
    var name: String        // e.g. "Wine Staging 11.18"
    var version: String
    var flavor: String      // "stable" | "devel" | "staging" | "gptk" | "crossover" | "wine"
    var url: URL
    var sizeBytes: Int64
    var publishedAt: Date?

    /// Builds from Sikarugir's public engine archive ship as `wswine.bundle` and rely on
    /// a few shared libraries that MacNative supplies from a Gcenx engine.
    var isWSBundle: Bool { url.lastPathComponent.hasPrefix("WS") }
    var isGcenxWine: Bool { ["stable", "devel", "staging"].contains(flavor) }
}

struct InstalledEngine: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var version: String
    var installedAt: Date
    /// `gptk` for Apple's Game Porting Toolkit Wine (D3DMetal); nil/"staging"/"devel" otherwise.
    var flavor: String?

    var isGPTK: Bool { flavor == "gptk" }
    var directory: URL { Paths.engines.appendingPathComponent(id, isDirectory: true) }
    /// Root of the Wine install (`bin/`, `lib/`, `share/`).
    var wineRoot: URL { directory.appendingPathComponent("wine", isDirectory: true) }
}

/// D3DMetal libraries imported from Apple's Game Porting Toolkit download.
struct D3DMetalImport: Codable, Hashable {
    var version: String
    var importedAt: Date

    var directory: URL { Paths.components.appendingPathComponent("d3dmetal/\(version)", isDirectory: true) }
    /// Mirrors Apple's `redist/lib`: `external/` (D3DMetal.framework) and `wine/<arch>/`.
    var lib: URL { directory.appendingPathComponent("lib", isDirectory: true) }
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
    /// CrossOver-based and other alternative builds (Sikarugir's public engine archive).
    private(set) var alternatives: [EngineRelease] = []
    private(set) var isLoadingCatalog = false
    var catalogError: String?

    static let dxvk = ComponentRelease(
        id: "dxvk", name: "DXVK-macOS (async)", version: "1.10.3-20230507-repack",
        url: URL(string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz")!)

    static let dxmt = ComponentRelease(
        id: "dxmt", name: "DXMT", version: "v0.80",
        url: URL(string: "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz")!)

    /// Apple's Game Porting Toolkit Wine, built by Gcenx (https://github.com/Gcenx/game-porting-toolkit).
    /// It ships D3DMetal and is one of the builds Apple's own GPTK Read Me points users to.
    private(set) var gptkRelease = EngineRelease(
        id: "gptk-3.0-3", name: "Game Porting Toolkit 3.0-3", version: "3.0-3", flavor: "gptk",
        url: URL(string: "https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz")!,
        sizeBytes: 239_200_808)

    /// A newer D3DMetal the user imported from Apple, layered over the GPTK engine.
    private(set) var d3dmetalImport: D3DMetalImport?

    /// Known-good fallback if the GitHub API is unreachable or rate limited.
    static let fallbackEngine = EngineRelease(
        id: "wine-staging-11.18", name: "Wine Staging 11.18", version: "11.18", flavor: "staging",
        url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-staging-11.18-osx64.tar.xz")!,
        sizeBytes: 193_105_336)

    init() {
        reloadInstalled()
        reloadD3DMetalImport()
    }

    func reloadInstalled() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Paths.engines, includingPropertiesForKeys: nil)) ?? []
        installed = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("engine.json")) else { return nil }
            return try? JSONDecoder.iso.decode(InstalledEngine.self, from: data)
        }
        .filter { WineContext.wineBinary(in: $0.wineRoot) != nil }
        .sorted { $0.installedAt > $1.installedAt }
    }

    /// Engines for regular games. The GPTK engine is reserved for the D3DMetal backend.
    var regularEngines: [InstalledEngine] { installed.filter { !$0.isGPTK } }
    var gptkEngine: InstalledEngine? { installed.first(where: \.isGPTK) }

    func engine(id: String?) -> InstalledEngine? {
        if let id, let e = installed.first(where: { $0.id == id }) { return e }
        return regularEngines.first
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
            let url = URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases?per_page=100")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let releases = try JSONDecoder.iso.decode([GitHubRelease].self, from: data)
            available = releases.flatMap { r in
                r.assets.compactMap { a -> EngineRelease? in
                    guard a.name.hasSuffix("-osx64.tar.xz") else { return nil }
                    guard let flavor = ["staging", "devel", "stable"].first(where: { a.name.hasPrefix("wine-\($0)") }) else {
                        return nil
                    }
                    return EngineRelease(
                        id: "wine-\(flavor)-\(r.tag_name)", name: "Wine \(flavor.capitalized) \(r.tag_name)",
                        version: r.tag_name, flavor: flavor, url: a.browser_download_url, sizeBytes: a.size,
                        publishedAt: r.published_at)
                }
            }
            .sorted { ($0.publishedAt ?? .distantPast, $0.flavor) > ($1.publishedAt ?? .distantPast, $1.flavor) }
            catalogError = nil
        } catch {
            catalogError = "Couldn't reach GitHub, showing the bundled default."
        }
        if available.isEmpty { available = [Self.fallbackEngine] }
        alternatives = await Self.fetchAlternatives()

        if let url = URL(string: "https://api.github.com/repos/Gcenx/game-porting-toolkit/releases?per_page=1"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let r = (try? JSONDecoder().decode([GitHubRelease].self, from: data))?.first,
           let a = r.assets.first(where: { $0.name.hasSuffix(".tar.xz") }) {
            let version = r.tag_name.replacingOccurrences(of: "Game-Porting-Toolkit-", with: "")
            gptkRelease = EngineRelease(id: "gptk-\(version)", name: "Game Porting Toolkit \(version)",
                                        version: version, flavor: "gptk", url: a.browser_download_url, sizeBytes: a.size)
        }
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
        do {
            try await extractEngine(archive, release: release, staging: staging, target: target)
        } catch {
            // Cancelled or failed: leave nothing half-installed behind.
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: target)
            throw error
        }

        let engine = InstalledEngine(id: release.id, name: release.name, version: release.version,
                                     installedAt: .now, flavor: release.flavor)
        try JSONEncoder.pretty.encode(engine).write(to: target.appendingPathComponent("engine.json"))
        reloadInstalled()
    }

    private func extractEngine(_ archive: URL, release: EngineRelease, staging: URL, target: URL) async throws {
        if release.isWSBundle {
            // Layout: wswine.bundle/{bin,lib,share}. Its binaries look for shared libraries one level
            // above the bundle (@loader_path/../../), so clone a Gcenx engine's libraries there.
            guard let donor = installed.first(where: { $0.flavor.map { ["stable", "devel", "staging"].contains($0) } ?? true }) else {
                throw SteamError(message: "Install a regular Wine engine first — \(release.name) borrows its libraries.")
            }
            try await Shell.extract(archive, to: staging)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: staging.appendingPathComponent("wswine.bundle"),
                                             to: target.appendingPathComponent("wine"))
            try? FileManager.default.removeItem(at: staging)
            let libs = donor.wineRoot.appendingPathComponent("lib")
            for file in (try? FileManager.default.contentsOfDirectory(atPath: libs.path)) ?? [] where file.hasSuffix(".dylib") {
                try await Shell.run("/bin/cp", ["-c", libs.appendingPathComponent(file).path, target.path])
            }
            _ = try? await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path])
            try Task.checkCancellation()
            return
        }
        // Archive layout: "Wine Staging.app/Contents/Resources/wine/{bin,lib,share}". Only that
        // subtree is wanted (the .app's own launcher would collide with the stripped `wine` folder).
        try await Shell.extract(archive, to: staging, stripComponents: 3, include: "*/Contents/Resources/wine/*")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging.appendingPathComponent("wine"),
                                         to: target.appendingPathComponent("wine"))
        try? FileManager.default.removeItem(at: staging)
        // Downloaded files are quarantined; clear it so Gatekeeper doesn't block every dylib.
        _ = try? await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path])
        try Task.checkCancellation()
    }

    /// Engines from bundles keep shared dylibs beside the `wine` folder; variants need them as well.
    static func cloneSharedLibraries(from dir: URL, to dest: URL) async throws {
        for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where file.hasSuffix(".dylib") {
            try await Shell.run("/bin/cp", ["-c", dir.appendingPathComponent(file).path, dest.path])
        }
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
        do {
            try await Shell.extract(archive, to: tmp, stripComponents: 1)
            try FileManager.default.moveItem(at: tmp, to: dir)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
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
        try await Self.cloneSharedLibraries(from: engine.directory, to: variant)
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
    var published_at: Date?
    var assets: [Asset]
}

extension EngineManager {
    /// Lists CrossOver-based (and other) open-source Wine builds from Sikarugir's public engine
    /// archive — downloaded as plain tarballs, no Sikarugir app involved. Keeps the newest revision of
    /// each build and skips variants MacNative doesn't need (32-bit-only, GPTK, single-game builds).
    fileprivate static func fetchAlternatives() async -> [EngineRelease] {
        guard let url = URL(string: "https://api.github.com/repos/Sikarugir-App/Engines/releases?per_page=20"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let releases = try? JSONDecoder.iso.decode([GitHubRelease].self, from: data) else { return [] }
        let pattern = #/^WS(\d+)(.+?)(?:_(\d+))?\.tar\.xz$/#
        var best: [String: (rank: (Int, Int), release: EngineRelease)] = [:]
        for r in releases {
            for a in r.assets {
                guard let m = a.name.wholeMatch(of: pattern) else { continue }
                let base = String(m.2)
                if base.contains("32Bit") || base.contains("GPTK") || base.contains("-") { continue }
                let rank = (Int(m.1) ?? 0, Int(m.3 ?? "0") ?? 0)
                guard let (name, version, flavor) = describe(base) else { continue }
                let release = EngineRelease(id: "ws-\(base.lowercased())", name: name, version: version,
                                            flavor: flavor, url: a.browser_download_url, sizeBytes: a.size,
                                            publishedAt: r.published_at)
                if let existing = best[base], existing.rank >= rank { continue }
                best[base] = (rank, release)
            }
        }
        return best.values.map(\.release).sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
    }

    private static func describe(_ base: String) -> (String, String, String)? {
        let prefixes: [(String, String, String)] = [
            ("WineCX", "CrossOver Wine", "crossover"),
            ("WhiskyWine", "Whisky Wine", "crossover"),
            ("WineSikarugir", "Wine", "wine"),
            ("Wine", "Wine", "wine"),
        ]
        for (prefix, label, flavor) in prefixes where base.hasPrefix(prefix) {
            let version = String(base.dropFirst(prefix.count))
            guard version.first?.isNumber == true else { return nil }
            let suffix = prefix == "WineSikarugir" ? " (Sikarugir build)" : ""
            return ("\(label) \(version)\(suffix)", version, flavor)
        }
        return nil
    }
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

// MARK: - D3DMetal (Apple Game Porting Toolkit)

extension EngineManager {
    enum D3DMetalError: LocalizedError {
        case notFound
        var errorDescription: String? {
            "Couldn't find D3DMetal in that file. Choose Apple's “Game Porting Toolkit” or “Evaluation environment for Windows games” .dmg, or a folder containing redist/lib."
        }
    }

    func reloadD3DMetalImport() {
        let file = Paths.components.appendingPathComponent("d3dmetal/current.json")
        d3dmetalImport = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder.iso.decode(D3DMetalImport.self, from: $0) }
        if let i = d3dmetalImport, !FileManager.default.fileExists(atPath: i.lib.path) { d3dmetalImport = nil }
    }

    /// Imports D3DMetal from Apple's download: the outer GPTK .dmg, the inner "Evaluation environment"
    /// .dmg, or a folder. Disk images are mounted read-only in MacNative's own folder and always detached.
    func importD3DMetal(from source: URL) async throws {
        var mounts: [URL] = []
        defer {
            let toDetach = mounts
            Task.detached {
                for m in toDetach.reversed() {
                    _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", m.path, "-force", "-quiet"])
                    try? FileManager.default.removeItem(at: m)
                }
            }
        }

        func mount(_ dmg: URL) async throws -> URL {
            let point = Paths.cache.appendingPathComponent("mnt-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)
            try await Shell.run("/usr/bin/hdiutil", ["attach", dmg.path, "-readonly", "-nobrowse", "-noverify",
                                                    "-mountpoint", point.path])
            mounts.append(point)
            return point
        }

        var root = source
        if source.pathExtension.lowercased() == "dmg" { root = try await mount(source) }

        var redistLib = Self.findRedistLib(in: root)
        if redistLib == nil {
            // The outer Game Porting Toolkit image nests the "Evaluation environment" image.
            let nested = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .first { $0.pathExtension.lowercased() == "dmg" && $0.lastPathComponent.localizedCaseInsensitiveContains("evaluation") }
            if let nested { redistLib = Self.findRedistLib(in: try await mount(nested)) }
        }
        guard let lib = redistLib else { throw D3DMetalError.notFound }
        try Task.checkCancellation()

        let info = lib.appendingPathComponent("external/D3DMetal.framework/Resources/Info.plist")
        let version = (NSDictionary(contentsOf: info)?["CFBundleShortVersionString"] as? String) ?? "imported"
        let entry = D3DMetalImport(version: version, importedAt: .now)

        let fm = FileManager.default
        try? fm.removeItem(at: entry.directory)
        try fm.createDirectory(at: entry.directory, withIntermediateDirectories: true)
        do {
            // ditto keeps the framework's symlinks intact.
            try await Shell.run("/usr/bin/ditto", [lib.path, entry.lib.path])
        } catch {
            try? fm.removeItem(at: entry.directory)
            throw error
        }
        // Replace any older import.
        let base = Paths.components.appendingPathComponent("d3dmetal")
        for old in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent != version && old.lastPathComponent != "current.json" {
            try? fm.removeItem(at: old)
        }
        try JSONEncoder.pretty.encode(entry).write(to: base.appendingPathComponent("current.json"))
        reloadD3DMetalImport()
    }

    func removeD3DMetalImport() {
        try? FileManager.default.removeItem(at: Paths.components.appendingPathComponent("d3dmetal"))
        for e in installed where e.isGPTK {
            try? FileManager.default.removeItem(at: e.directory.appendingPathComponent("variants"))
        }
        d3dmetalImport = nil
    }

    /// Finds a `lib` folder laid out like Apple's `redist/lib` (contains `external/D3DMetal.framework`).
    private static func findRedistLib(in root: URL) -> URL? {
        let fm = FileManager.default
        for candidate in [root.appendingPathComponent("redist/lib"), root.appendingPathComponent("lib"), root]
            where fm.fileExists(atPath: candidate.appendingPathComponent("external/D3DMetal.framework").path) {
            return candidate
        }
        // Shallow search (handles an extra wrapping folder).
        let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = e?.nextObject() as? URL {
            if e!.level > 4 { e!.skipDescendants(); continue }
            if url.lastPathComponent == "D3DMetal.framework", url.deletingLastPathComponent().lastPathComponent == "external" {
                return url.deletingLastPathComponent().deletingLastPathComponent()
            }
        }
        return nil
    }

    /// The GPTK engine with the imported D3DMetal layered on top, as an APFS clone (Apple's Read Me
    /// describes the same swap of `lib/external` and the D3D libraries in `lib/wine`).
    func d3dmetalVariant(of engine: InstalledEngine, using d3d: D3DMetalImport) async throws -> URL {
        let variant = engine.directory.appendingPathComponent("variants/d3dmetal-\(d3d.version)", isDirectory: true)
        let wine = variant.appendingPathComponent("wine")
        if WineContext.wineBinary(in: wine) != nil { return wine }

        let fm = FileManager.default
        try? fm.removeItem(at: variant)
        try fm.createDirectory(at: variant, withIntermediateDirectories: true)
        do {
            try await Shell.run("/bin/cp", ["-cR", engine.wineRoot.path, wine.path])
            let external = wine.appendingPathComponent("lib/external")
            try? fm.removeItem(at: external)
            try await Shell.run("/usr/bin/ditto", [d3d.lib.appendingPathComponent("external").path, external.path])
            for arch in ["x86_64-unix", "x86_64-windows", "i386-windows"] {
                let src = d3d.lib.appendingPathComponent("wine/\(arch)")
                let dst = wine.appendingPathComponent("lib/wine/\(arch)")
                for file in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] {
                    let to = dst.appendingPathComponent(file)
                    try? fm.removeItem(at: to)
                    try fm.copyItem(at: src.appendingPathComponent(file), to: to)
                }
            }
        } catch {
            try? fm.removeItem(at: variant)
            throw error
        }
        return wine
    }
}
