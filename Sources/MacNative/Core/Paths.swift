import Foundation

/// Every file MacNative writes lives under one root folder, so the app is fully self-contained:
/// engines, prefixes, downloads, logs and caches. Deleting that folder removes everything.
///
/// Root resolution order:
/// 1. `MACNATIVE_HOME` environment variable.
/// 2. A `portable-data-path` file inside the app bundle's Resources (written by `scripts/build.sh`
///    for development builds, so they keep their data inside the repo).
/// 3. `~/Library/Application Support/MacNative`.
enum Paths {
    static let root: URL = {
        let fm = FileManager.default
        let url: URL
        if let env = ProcessInfo.processInfo.environment["MACNATIVE_HOME"], !env.isEmpty {
            url = URL(fileURLWithPath: env, isDirectory: true)
        } else if let marker = Bundle.main.url(forResource: "portable-data-path", withExtension: nil),
                  let raw = try? String(contentsOf: marker, encoding: .utf8),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            url = URL(fileURLWithPath: raw.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        } else {
            url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacNative", isDirectory: true)
        }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var engines: URL { dir("engines") }
    static var components: URL { dir("components") }
    static var prefixes: URL { dir("prefixes") }
    static var downloads: URL { dir("downloads") }
    static var logs: URL { dir("logs") }
    static var cache: URL { dir("cache") }
    static var accounts: URL { dir("accounts") }

    /// Everything MacNative creates under `root`. "Erase everything" deletes exactly these, never
    /// the root itself, so a custom `MACNATIVE_HOME` pointing at a shared folder stays safe.
    static var ownedItems: [URL] {
        ["engines", "components", "prefixes", "downloads", "logs", "cache", "accounts",
         "library.json", "settings.json"].map { root.appendingPathComponent($0) }
    }

    static var libraryFile: URL { root.appendingPathComponent("library.json") }
    static var settingsFile: URL { root.appendingPathComponent("settings.json") }

    private static func dir(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
