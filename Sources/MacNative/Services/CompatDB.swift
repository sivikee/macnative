import Foundation
import Observation

/// Community compatibility database (`compat/games.json` in the repository): status, notes and
/// known-good settings per game, applied automatically — MacNative's take on GameNative's known configs.
struct CompatEntry: Codable, Hashable {
    enum Status: String, Codable {
        case works, playable, broken, unknown
    }

    var store: String
    var id: String
    var title: String
    var status: Status
    var revision: Int
    var notes: String?
    var testedWith: String?
    var config: [String: JSONValue]?

    var key: String { "\(store):\(id)" }

    /// Applies this entry's settings on top of `base`.
    func apply(to base: GameConfig) -> GameConfig {
        var c = base
        for (key, value) in config ?? [:] {
            switch key {
            case "graphics": if let v = value.string.flatMap(GraphicsBackend.init) { c.graphics = v }
            case "windowsVersion": if let v = value.string.flatMap(WindowsVersion.init) { c.windowsVersion = v }
            case "sync": if let v = value.string.flatMap(SyncMode.init) { c.sync = v }
            case "engine": c.engineID = value.string
            case "retinaMode": if let v = value.bool { c.retinaMode = v }
            case "advertiseAVX": if let v = value.bool { c.advertiseAVX = v }
            case "dxvkAsync": if let v = value.bool { c.dxvkAsync = v }
            case "commandAsControl": if let v = value.bool { c.commandAsControl = v }
            case "useSteamClient": if let v = value.bool { c.useSteamClient = v }
            case "stripSteamStub": if let v = value.bool { c.stripSteamStub = v }
            case "virtualDesktop": c.virtualDesktop = value.string
            case "fpsLimit": if let v = value.number { c.fpsLimit = Int(v) }
            case "launchArguments": if let v = value.string { c.launchArguments = v }
            case "dllOverrides": if let v = value.string { c.dllOverrides = v }
            case "environment":
                if case let .object(env) = value {
                    for (k, v) in env.sorted(by: { $0.key < $1.key }) {
                        guard let s = v.string else { continue }
                        c.environment.removeAll { $0.key == k }
                        c.environment.append(EnvVar(key: k, value: s))
                    }
                }
            default: break
            }
        }
        return c
    }
}

/// Minimal JSON value so `config` can hold strings, numbers, booleans and objects.
enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(s): try c.encode(s)
        case let .number(n): try c.encode(n)
        case let .bool(b): try c.encode(b)
        case let .object(o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    var string: String? { if case let .string(s) = self { s } else { nil } }
    var bool: Bool? { if case let .bool(b) = self { b } else { nil } }
    var number: Double? { if case let .number(n) = self { n } else { nil } }
}

@MainActor
@Observable
final class CompatDB {
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/sivikee/macnative/refs/heads/main/compat/games.json")!
    static let issueURL = "https://github.com/sivikee/macnative/issues/new"

    private(set) var entries: [String: CompatEntry] = [:]

    private struct File: Codable { var schema: Int; var games: [CompatEntry] }
    private static var cacheURL: URL { Paths.cache.appendingPathComponent("compat-games.json") }

    init() {
        // Newest local copy first: the cached download, else the copy bundled with the app.
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Compat/games.json")
        for url in [Self.cacheURL, bundled].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url), load(data) { break }
        }
    }

    @discardableResult
    private func load(_ data: Data) -> Bool {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.schema == 1 else { return false }
        entries = Dictionary(file.games.map { ($0.key, $0) }, uniquingKeysWith: { a, b in a.revision >= b.revision ? a : b })
        return true
    }

    /// Fetches the latest database from GitHub (no-op offline).
    func refresh() async {
        var request = URLRequest(url: Self.remoteURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, load(data) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    func entry(for game: Game) -> CompatEntry? { entries["\(game.source.rawValue):\(game.externalID)"] }
}
