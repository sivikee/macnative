import Foundation

/// The optional Windows Steam client, run in its own prefix. Native Steam (`SteamStore`) is the
/// default; games only use this when their "Use Steam client" setting is on.
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

    static func coverURL(_ appID: String) -> URL {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_600x900_2x.jpg")!
    }

    static func heroURL(_ appID: String) -> URL {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_hero.jpg")!
    }
}
