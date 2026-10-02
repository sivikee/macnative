import Foundation

enum GameSource: String, Codable, CaseIterable, Identifiable {
    case steam, gog, custom
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .steam: "Steam"
        case .gog: "GOG"
        case .custom: "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .steam: "cloud.fill"
        case .gog: "g.circle.fill"
        case .custom: "folder.fill"
        }
    }
}

enum InstallState: String, Codable {
    case notInstalled
    case installed
}

struct Game: Identifiable, Codable, Hashable {
    /// Stable key, e.g. `steam:620`, `gog:1207658924`, `custom:<uuid>`.
    var id: String
    var source: GameSource
    var externalID: String
    var title: String

    var coverURL: URL?
    var heroURL: URL?
    var developer: String?
    var releaseYear: Int?

    var installState: InstallState = .notInstalled
    /// Unix path of the Windows executable (for GOG / custom games).
    var executablePath: String?
    var workingDirectory: String?
    var installDirectory: String?
    var installSizeBytes: Int64?

    var isFavorite = false
    var lastPlayed: Date?
    var playTimeSeconds: Double = 0

    var config: GameConfig

    /// Name of the Wine prefix this game runs in (folder under `Paths.prefixes`).
    var prefixName: String

    var isInstalled: Bool { installState == .installed }
}

/// How Direct3D calls are translated on macOS.
enum GraphicsBackend: String, Codable, CaseIterable, Identifiable {
    /// Wine's own D3D → OpenGL translation. Most compatible, slowest.
    case wined3d
    /// DXVK-macOS: D3D10/11 → Vulkan → MoltenVK → Metal.
    case dxvk
    /// DXMT: D3D10/11 → Metal directly. Fastest for many DX11 titles, still experimental.
    case dxmt
    /// Apple's D3DMetal (Game Porting Toolkit): D3D11/12 → Metal. The only DirectX 12 path on macOS.
    case d3dmetal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wined3d: "WineD3D (OpenGL)"
        case .dxvk: "DXVK (Vulkan → Metal)"
        case .dxmt: "DXMT (Metal)"
        case .d3dmetal: "D3DMetal (DX12 → Metal)"
        }
    }

    var detail: String {
        switch self {
        case .wined3d: "Built into Wine. Best compatibility for DirectX 9 and older games."
        case .dxvk: "DirectX 10/11 over MoltenVK. Solid default for most DX11 games."
        case .dxmt: "DirectX 10/11 straight to Metal. Often fastest, but experimental."
        case .d3dmetal: "Apple's translation layer, needed for DirectX 12 games. Uses its own Wine, downloaded on first launch."
        }
    }

    var componentID: String? {
        switch self {
        case .wined3d: nil
        case .dxvk: "dxvk"
        case .dxmt: "dxmt"
        case .d3dmetal: nil
        }
    }
}

enum WindowsVersion: String, Codable, CaseIterable, Identifiable {
    case win11, win10, win81, win7, winxp64
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .win11: "Windows 11"
        case .win10: "Windows 10"
        case .win81: "Windows 8.1"
        case .win7: "Windows 7"
        case .winxp64: "Windows XP"
        }
    }
}

enum SyncMode: String, Codable, CaseIterable, Identifiable {
    case msync, esync, none
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .msync: "MSync (recommended)"
        case .esync: "ESync"
        case .none: "Off"
        }
    }
}

struct EnvVar: Codable, Hashable, Identifiable {
    var id = UUID()
    var key: String
    var value: String
}

/// Per-game runtime configuration — the macOS-relevant subset of GameNative's container config.
struct GameConfig: Codable, Hashable {
    /// `nil` → use the default engine from app settings.
    var engineID: String?
    var graphics: GraphicsBackend = .dxvk
    var windowsVersion: WindowsVersion = .win10
    var sync: SyncMode = .msync

    /// Render at native Retina resolution instead of scaled points.
    var retinaMode = false
    /// Expose AVX/AVX2 to Rosetta-translated code (macOS 15+).
    var advertiseAVX = true
    var metalHUD = false
    var dxvkHUD = false
    var dxvkAsync = true
    /// 0 = unlimited.
    var fpsLimit = 0
    /// Map ⌘ to Ctrl so Windows shortcuts work.
    var commandAsControl = true

    /// Run inside a Wine virtual desktop of the given size (e.g. "1920x1080"), or nil for normal windows.
    var virtualDesktop: String?

    var launchArguments = ""
    /// Extra `WINEDLLOVERRIDES` entries, e.g. `xinput1_3=n,b`.
    var dllOverrides = ""
    var environment: [EnvVar] = []

    /// Steam only: launch through the Windows Steam client instead of natively (for heavy DRM/anti-cheat).
    var useSteamClient = false
    /// Steam only: strip SteamStub DRM with Steamless before launching (opt-in).
    var stripSteamStub = false

    static let `default` = GameConfig()
}

extension GameConfig {
    /// Lenient decoding: fields added in newer versions fall back to their defaults instead of
    /// failing to load the whole library.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameConfig()
        engineID = try c.decodeIfPresent(String.self, forKey: .engineID)
        graphics = (try? c.decodeIfPresent(GraphicsBackend.self, forKey: .graphics)) ?? d.graphics
        windowsVersion = (try? c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion)) ?? d.windowsVersion
        sync = (try? c.decodeIfPresent(SyncMode.self, forKey: .sync)) ?? d.sync
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? d.retinaMode
        advertiseAVX = try c.decodeIfPresent(Bool.self, forKey: .advertiseAVX) ?? d.advertiseAVX
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? d.metalHUD
        dxvkHUD = try c.decodeIfPresent(Bool.self, forKey: .dxvkHUD) ?? d.dxvkHUD
        dxvkAsync = try c.decodeIfPresent(Bool.self, forKey: .dxvkAsync) ?? d.dxvkAsync
        fpsLimit = try c.decodeIfPresent(Int.self, forKey: .fpsLimit) ?? d.fpsLimit
        commandAsControl = try c.decodeIfPresent(Bool.self, forKey: .commandAsControl) ?? d.commandAsControl
        virtualDesktop = try c.decodeIfPresent(String.self, forKey: .virtualDesktop)
        launchArguments = try c.decodeIfPresent(String.self, forKey: .launchArguments) ?? d.launchArguments
        dllOverrides = try c.decodeIfPresent(String.self, forKey: .dllOverrides) ?? d.dllOverrides
        environment = try c.decodeIfPresent([EnvVar].self, forKey: .environment) ?? d.environment
        useSteamClient = try c.decodeIfPresent(Bool.self, forKey: .useSteamClient) ?? d.useSteamClient
        stripSteamStub = try c.decodeIfPresent(Bool.self, forKey: .stripSteamStub) ?? d.stripSteamStub
    }
}
