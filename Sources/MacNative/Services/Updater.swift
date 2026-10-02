import AppKit
import Observation

/// Checks GitHub Releases for a newer MacNative and installs it in place.
@MainActor
@Observable
final class Updater {
    struct Release: Equatable {
        var version: String
        var notesURL: URL
        var zipURL: URL
        var size: Int64
    }

    static let repo = "sivikee/macnative"

    private(set) var available: Release?
    private(set) var isChecking = false
    private(set) var isInstalling = false
    private(set) var lastError: String?
    var dismissedVersion: String?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Dev builds (portable data folder) and `swift run` never self-update.
    var canSelfUpdate: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.url(forResource: "portable-data-path", withExtension: nil) == nil
    }

    var showBanner: Bool { available != nil && available?.version != dismissedVersion && canSelfUpdate }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        lastError = nil
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=10") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct R: Decodable {
                struct Asset: Decodable { var name: String; var size: Int64; var browser_download_url: URL }
                var tag_name: String; var draft: Bool; var html_url: URL; var assets: [Asset]
            }
            let releases = try JSONDecoder().decode([R].self, from: data).filter { !$0.draft }
            let newest = releases.compactMap { r -> Release? in
                guard let zip = r.assets.first(where: { $0.name.hasSuffix("-macOS-arm64.zip") }) else { return nil }
                let v = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
                return Release(version: v, notesURL: r.html_url, zipURL: zip.browser_download_url, size: zip.size)
            }
            .max { Self.compare($0.version, $1.version) < 0 }
            available = newest.flatMap { Self.compare($0.version, currentVersion) > 0 ? $0 : nil }
        } catch {
            lastError = "Couldn't check for updates."
        }
    }

    /// Numeric dotted-version comparison ("0.1.10" > "0.1.9").
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// Downloads the new version, swaps it in after MacNative quits, and relaunches.
    func install(progress: @escaping Downloader.Progress) async throws {
        guard let release = available else { return }
        let appURL = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(release.notesURL)
            throw SteamError(message: "MacNative can't replace itself in \(appURL.deletingLastPathComponent().path). Download the update from the release page.")
        }
        isInstalling = true
        defer { isInstalling = false }

        let work = Paths.downloads.appendingPathComponent("update-\(release.version)", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        let zip = try await Downloader.download(release.zipURL, into: work, progress: progress)
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let newApp = unpacked.appendingPathComponent("MacNative.app")

        // Sanity checks: it's MacNative, and it's the version we expect.
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              Self.compare(version, currentVersion) > 0 else {
            throw SteamError(message: "The downloaded update doesn't look right, so it wasn't installed.")
        }
        _ = try? await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        // A tiny helper waits for this process to exit, swaps the bundles, relaunches, cleans up.
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(appURL.path).old"
        mv "\(appURL.path)" "\(appURL.path).old" || exit 1
        # If the new app can't be moved in, put the old one back.
        if mv "\(newApp.path)" "\(appURL.path)"; then rm -rf "\(appURL.path).old"; else mv "\(appURL.path).old" "\(appURL.path)"; fi
        rm -rf "\(work.path)"
        open "\(appURL.path)"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        try helper.run()
        NSApp.terminate(nil)
    }
}
