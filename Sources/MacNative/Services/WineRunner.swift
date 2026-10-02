import Foundation

/// Everything needed to run one Windows program: which Wine, which prefix, which config.
struct WineContext {
    var wineRoot: URL
    var prefix: URL
    var config: GameConfig
    var verboseLogging = false

    var wineBinary: URL { wineRoot.appendingPathComponent("bin/wine") }
    var wineserverBinary: URL { wineRoot.appendingPathComponent("bin/wineserver") }

    var environment: [String: String] {
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "PATH": "\(wineRoot.path)/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "WINEPREFIX": prefix.path,
            "WINEDEBUG": verboseLogging ? "err+all,warn+module,fixme-all" : "-all",
            // Recover instead of crashing when Metal reports a lost device (common on mode switches).
            "MVK_CONFIG_RESUME_LOST_DEVICE": "1",
        ]

        switch config.sync {
        case .msync: env["WINEMSYNC"] = "1"
        case .esync: env["WINEESYNC"] = "1"
        case .none: break
        }
        if config.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        if config.metalHUD { env["MTL_HUD_ENABLED"] = "1" }

        if config.graphics == .dxvk {
            if config.dxvkHUD { env["DXVK_HUD"] = "fps,devinfo" }
            if config.dxvkAsync { env["DXVK_ASYNC"] = "1" }
            if config.fpsLimit > 0 { env["DXVK_FRAME_RATE"] = String(config.fpsLimit) }
        }

        env["WINEDLLOVERRIDES"] = dllOverrides

        for v in config.environment where !v.key.trimmingCharacters(in: .whitespaces).isEmpty {
            env[v.key] = v.value
        }
        return env
    }

    private var dllOverrides: String {
        // winemenubuilder would create .desktop/.lnk junk and file associations — never wanted here.
        var parts = ["winemenubuilder.exe=d"]
        switch config.graphics {
        case .dxvk: parts.append("d3d11,d3d10core=n,b")
        // DXMT lives in the engine variant's builtin folder; WineD3D is plain builtin.
        case .dxmt, .wined3d: parts.append("d3d11,d3d10core,dxgi=b")
        }
        let user = config.dllOverrides.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty { parts.append(user) }
        return parts.joined(separator: ";")
    }
}

enum WineRunner {
    /// Creates the prefix if needed and applies settings that live in the Wine registry.
    static func preparePrefix(_ ctx: WineContext) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: ctx.prefix, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: ctx.prefix.appendingPathComponent("system.reg").path) {
            try await Shell.run(ctx.wineBinary.path, ["wineboot", "--init"], environment: ctx.environment)
            try await waitForWineserver(ctx)
        }

        // Re-apply registry settings only when they changed since the last launch.
        let stateFile = ctx.prefix.appendingPathComponent(".macnative-registry")
        let wanted = registrySignature(ctx.config)
        if (try? String(contentsOf: stateFile, encoding: .utf8)) != wanted {
            let yn: (Bool) -> String = { $0 ? "y" : "n" }
            let mac = #"HKCU\Software\Wine\Mac Driver"#
            try await reg(ctx, ["add", mac, "/v", "RetinaMode", "/t", "REG_SZ", "/d", yn(ctx.config.retinaMode), "/f"])
            try await reg(ctx, ["add", mac, "/v", "LeftCommandIsCtrl", "/t", "REG_SZ", "/d", yn(ctx.config.commandAsControl), "/f"])
            try await reg(ctx, ["add", mac, "/v", "RightCommandIsCtrl", "/t", "REG_SZ", "/d", yn(ctx.config.commandAsControl), "/f"])
            try await Shell.run(ctx.wineBinary.path, ["winecfg", "/v", ctx.config.windowsVersion.rawValue],
                                environment: ctx.environment)
            try await waitForWineserver(ctx)
            try wanted.write(to: stateFile, atomically: true, encoding: .utf8)
        }
    }

    /// Copies DXVK's native DLLs into the prefix. They are only used when the DLL override says
    /// `n,b`, so switching back to WineD3D/DXMT never requires removing them.
    static func installDXVK(from component: URL, into prefix: URL) throws {
        let fm = FileManager.default
        let pairs = [("x64", "drive_c/windows/system32"), ("x32", "drive_c/windows/syswow64")]
        for (src, dst) in pairs {
            let from = component.appendingPathComponent(src)
            let to = prefix.appendingPathComponent(dst)
            guard fm.fileExists(atPath: to.path) else { continue }
            for dll in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] where dll.hasSuffix(".dll") {
                let target = to.appendingPathComponent(dll)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: from.appendingPathComponent(dll), to: target)
            }
        }
    }

    /// Starts a Windows program and returns the running process. Output goes to `log`.
    static func launch(_ ctx: WineContext, executable: String, arguments: [String],
                       workingDirectory: URL?, log: URL) throws -> Process {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)

        var wineArgs: [String]
        if let desktop = ctx.config.virtualDesktop, !desktop.isEmpty {
            wineArgs = ["explorer", "/desktop=MacNative,\(desktop)", executable]
        } else {
            wineArgs = ["start", "/wait", "/unix", executable]
        }
        wineArgs += arguments
        wineArgs += splitArguments(ctx.config.launchArguments)

        let process = Process()
        process.executableURL = ctx.wineBinary
        process.arguments = wineArgs
        process.environment = ctx.environment
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process
    }

    /// Runs a Windows program to completion (used for installers).
    static func runToCompletion(_ ctx: WineContext, executable: String, arguments: [String],
                                log: URL? = nil) async throws {
        let output = try await Shell.run(ctx.wineBinary.path, [executable] + arguments, environment: ctx.environment)
        if let log { try? output.write(to: log, atomically: true, encoding: .utf8) }
        try await waitForWineserver(ctx)
    }

    /// Kills every process in the prefix.
    static func kill(_ ctx: WineContext) async {
        _ = try? await Shell.run(ctx.wineserverBinary.path, ["-k"], environment: ctx.environment)
    }

    static func waitForWineserver(_ ctx: WineContext) async throws {
        _ = try? await Shell.run(ctx.wineserverBinary.path, ["-w"], environment: ctx.environment)
    }

    private static func reg(_ ctx: WineContext, _ args: [String]) async throws {
        try await Shell.run(ctx.wineBinary.path, ["reg"] + args, environment: ctx.environment)
    }

    private static func registrySignature(_ c: GameConfig) -> String {
        "v1|\(c.retinaMode)|\(c.commandAsControl)|\(c.windowsVersion.rawValue)"
    }

    /// Splits a user-entered argument string, honoring double quotes.
    static func splitArguments(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for ch in s {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch == " " && !inQuotes {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
