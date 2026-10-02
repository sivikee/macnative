import Foundation

/// Launches native Steam games without the Steam client, the way GameNative does: gbe_fork's
/// experimental steamclient (LGPL-3.0, https://github.com/Detanup01/gbe_fork) plays the role of
/// Steam, started through its ColdClientLoader with a generated `steam_settings` folder carrying
/// the real account id, owned DLC and an encrypted app ticket from Steam.
enum SteamLauncher {
    static let gbe = ComponentRelease(
        id: "gbe_fork", name: "gbe_fork", version: "release-2026_09_27",
        url: URL(string: "https://github.com/Detanup01/gbe_fork/releases/download/release-2026_09_27/emu-win-release-vs22.7z")!)

    struct Plan {
        var loader: URL          // unix path of steamclient_loader_x64/x86.exe inside the prefix
        var steamDir: URL
    }

    /// Prepares `C:\Program Files (x86)\Steam` in the game's prefix and returns what to run.
    static func prepare(prefix: URL, appID: UInt32, app: SteamAppInfo?, executable: URL, workingDirectory: URL?,
                        arguments: String, account: SteamSession.Account, ownedDLC: [UInt32],
                        ticket: Data?, injectStubPatcher: Bool, engines: EngineManager) async throws -> Plan {
        let gbeRoot = try await engines.ensureComponent(gbe)
        let source = gbeRoot.appendingPathComponent("steamclient_experimental")
        let steamDir = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: steamDir, withIntermediateDirectories: true)

        for name in ["steamclient.dll", "steamclient64.dll", "steamclient_loader_x64.exe", "steamclient_loader_x86.exe",
                     "GameOverlayRenderer.dll", "GameOverlayRenderer64.dll"] {
            let to = steamDir.appendingPathComponent(name)
            try? fm.removeItem(at: to)
            try fm.copyItem(at: source.appendingPathComponent(name), to: to)
        }
        let extra = steamDir.appendingPathComponent("extra_dlls")
        try? fm.removeItem(at: extra)
        if injectStubPatcher {
            try fm.copyItem(at: source.appendingPathComponent("extra_dlls"), to: extra)
        }

        let ini = """
        [SteamClient]
        Exe=\(windowsPath(executable))
        ExeRunDir=\(windowsPath(workingDirectory ?? executable.deletingLastPathComponent()))
        ExeCommandLine=\(arguments)
        AppId=\(appID)
        SteamClientDll=steamclient.dll
        SteamClient64Dll=steamclient64.dll

        [Injection]
        ForceInjectSteamClient=0
        ForceInjectGameOverlayRenderer=0
        DllsToInjectFolder=\(injectStubPatcher ? "extra_dlls" : "")
        IgnoreInjectionError=1
        IgnoreLoaderArchDifference=1

        [Persistence]
        Mode=0

        [Debug]
        ResumeByDebugger=0

        """
        try ini.write(to: steamDir.appendingPathComponent("ColdClientLoader.ini"), atomically: true, encoding: .utf8)
        try writeSettings(steamDir.appendingPathComponent("steam_settings", isDirectory: true), appID: appID,
                          app: app, account: account, ownedDLC: ownedDLC, ticket: ticket)

        let loader = PEInfo.is64Bit(executable) ? "steamclient_loader_x64.exe" : "steamclient_loader_x86.exe"
        return Plan(loader: steamDir.appendingPathComponent(loader), steamDir: steamDir)
    }

    private static func writeSettings(_ dir: URL, appID: UInt32, app: SteamAppInfo?, account: SteamSession.Account,
                                      ownedDLC: [UInt32], ticket: Data?) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var user = """
        [user::general]
        account_name=\(account.accountName)
        account_steamid=\(account.steamID)
        language=english

        """
        if let ticket { user += "ticket=\(ticket.base64EncodedString())\n" }
        // ISteamRemoteStorage files go to Steam's own userdata layout (<path>/<appid>/remote),
        // where Steam Cloud sync picks them up.
        user += "\n[user::saves]\nlocal_save_path=C:\\Program Files (x86)\\Steam\\userdata\\\(account.accountID)\n"
        try user.write(to: dir.appendingPathComponent("configs.user.ini"), atomically: true, encoding: .utf8)

        var appIni = """
        [app::general]
        is_beta_branch=0
        branch_name=public

        [app::dlcs]
        unlock_all=0

        """
        for dlc in ownedDLC { appIni += "\(dlc)=DLC \(dlc)\n" }
        try appIni.write(to: dir.appendingPathComponent("configs.app.ini"), atomically: true, encoding: .utf8)

        let main = """
        [main::general]
        new_app_ticket=1
        gc_token=1

        [main::connectivity]
        disable_lan_only=0
        disable_networking=0
        offline=0

        """
        try main.write(to: dir.appendingPathComponent("configs.main.ini"), atomically: true, encoding: .utf8)
        try String(appID).write(to: dir.appendingPathComponent("steam_appid.txt"), atomically: true, encoding: .utf8)
    }

    /// Wine maps the Mac's root as drive Z:.
    static func windowsPath(_ url: URL) -> String {
        "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
    }
}

enum PEInfo {
    /// Reads the PE header machine field: 0x8664 = x86-64, 0x14C = i386.
    static func is64Bit(_ exe: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: exe) else { return true }
        defer { try? h.close() }
        guard let dos = try? h.read(upToCount: 64), dos.count == 64, dos.prefix(2) == Data("MZ".utf8) else { return true }
        let peOffset = dos.subdata(in: 60..<64).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        try? h.seek(toOffset: UInt64(peOffset))
        guard let pe = try? h.read(upToCount: 6), pe.count == 6, pe.prefix(4) == Data([0x50, 0x45, 0, 0]) else { return true }
        let machine = pe.subdata(in: 4..<6).withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
        return machine != 0x14C
    }
}
