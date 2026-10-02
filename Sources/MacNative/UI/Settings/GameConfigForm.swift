import SwiftUI

/// Editor for a `GameConfig`, used both for app-wide defaults and per-game overrides.
/// Grouped like GameNative's container config: Engine & graphics, Display, Performance, Advanced.
struct GameConfigForm: View {
    @Environment(AppState.self) private var app
    @Binding var config: GameConfig
    var showsEngine: Bool
    /// Show Steam-only options (launch mode, DRM).
    var steamOptions = false

    private static let desktopSizes = ["1280x720", "1280x800", "1440x900", "1600x900", "1920x1080", "1920x1200", "2560x1440"]
    private static let fpsOptions = [0, 30, 60, 90, 120]

    var body: some View {
        if steamOptions {
            SettingsCard(title: "Steam", subtitle: "Native mode runs without the Steam client, through gbe_fork") {
                toggle("macwindow", Theme.statusAvailable, "Use the Windows Steam client",
                       "Fallback for heavy DRM or anti-cheat. The client must install the game itself.", $config.useSteamClient)
                if !config.useSteamClient {
                    toggle("lock.open.fill", Theme.warning, "Patch SteamStub DRM in memory",
                           "Only for games that refuse to start natively. Uses gbe_fork's stub patcher; off by default.",
                           $config.stripSteamStub)
                }
            }
        }
        SettingsCard(title: "Graphics", subtitle: "How DirectX is translated to Metal") {
            if config.graphics == .d3dmetal {
                SettingsRow(symbol: "wineglass", tint: Theme.pink, title: "Wine engine",
                            subtitle: "D3DMetal always runs on Apple's Game Porting Toolkit Wine") {
                    Text(app.engineDescription(for: config)).font(Theme.font(12)).foregroundStyle(Theme.muted)
                }
            } else if showsEngine {
                let installedIDs = Set(app.engines.installed.map(\.id))
                let downloadable = (app.engines.available + app.engines.alternatives).filter { !installedIDs.contains($0.id) }
                SettingsRow(symbol: "wineglass", tint: Theme.pink, title: "Wine engine",
                            subtitle: config.engineID.flatMap { id in installedIDs.contains(id) ? nil : "Downloads before the next launch" }) {
                    Picker("", selection: Binding(
                        get: { config.engineID },
                        set: { id in
                            config.engineID = id
                            // Start downloading a not-yet-installed engine right away.
                            if let id, !installedIDs.contains(id),
                               let release = downloadable.first(where: { $0.id == id }) { app.installEngine(release) }
                        })) {
                        Text("Default").tag(String?.none)
                        Section("Installed") {
                            ForEach(app.engines.regularEngines) { e in Text(e.name).tag(String?.some(e.id)) }
                        }
                        if !downloadable.isEmpty {
                            Section("Download") {
                                ForEach(downloadable) { r in Text("\(r.name) (\(Format.bytes(r.sizeBytes)))").tag(String?.some(r.id)) }
                            }
                        }
                    }
                    .labelsHidden().frame(width: 220)
                }
            }
            SettingsRow(symbol: "cube.transparent", tint: Theme.tertiary, title: "Graphics backend",
                        subtitle: config.graphics.detail) {
                Picker("", selection: $config.graphics) {
                    ForEach(GraphicsBackend.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(width: 200)
            }
            if config.graphics == .dxvk || config.graphics == .d3dmetal {
                SettingsRow(symbol: "speedometer", tint: Theme.purple, title: "Frame rate limit") {
                    Picker("", selection: $config.fpsLimit) {
                        ForEach(Self.fpsOptions, id: \.self) { Text($0 == 0 ? "Unlimited" : "\($0) FPS").tag($0) }
                    }
                    .labelsHidden().frame(width: 140)
                }
            }
            if config.graphics == .dxvk {
                toggle("bolt.fill", Theme.warning, "DXVK async shaders", "Less stutter while shaders compile", $config.dxvkAsync)
                toggle("chart.bar.fill", Theme.success, "DXVK HUD", "FPS and GPU info overlay", $config.dxvkHUD)
            }
            toggle("gauge.with.dots.needle.67percent", Theme.success, "Metal performance HUD",
                   "Apple's built-in FPS / frame time overlay", $config.metalHUD)
        }

        SettingsCard(title: "Display & input") {
            toggle("sparkles.tv", Theme.tertiary, "Retina mode", "Render at full native resolution (heavier)", $config.retinaMode)
            SettingsRow(symbol: "macwindow", tint: Theme.purple, title: "Virtual desktop",
                        subtitle: "Run inside a fixed-size window, useful for games that misbehave in fullscreen") {
                Picker("", selection: $config.virtualDesktop) {
                    Text("Off").tag(String?.none)
                    ForEach(Self.desktopSizes, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden().frame(width: 140)
            }
            toggle("command", Theme.pink, "⌘ acts as Ctrl", "Windows shortcuts work with the Command key", $config.commandAsControl)
        }

        SettingsCard(title: "Compatibility & performance") {
            SettingsRow(symbol: "pc", tint: Theme.statusAvailable, title: "Windows version") {
                Picker("", selection: $config.windowsVersion) {
                    ForEach(WindowsVersion.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(width: 160)
            }
            SettingsRow(symbol: "arrow.triangle.2.circlepath", tint: Theme.success, title: "Synchronization",
                        subtitle: "MSync uses macOS kernel primitives for faster threading") {
                Picker("", selection: $config.sync) {
                    ForEach(SyncMode.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(width: 180)
            }
            toggle("cpu", Theme.warning, "Advertise AVX", "Lets Rosetta expose AVX/AVX2 (needed by some newer games)", $config.advertiseAVX)
        }

        SettingsCard(title: "Advanced") {
            textRow("terminal", "Launch arguments", "-dx11 -windowed", $config.launchArguments)
            textRow("puzzlepiece.extension", "DLL overrides", "xinput1_3=n,b;dinput8=n,b", $config.dllOverrides)
            EnvironmentEditor(vars: $config.environment)
        }
    }

    private func toggle(_ symbol: String, _ tint: Color, _ title: String, _ subtitle: String?, _ value: Binding<Bool>) -> some View {
        SettingsRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle) {
            Toggle("", isOn: value).toggleStyle(.switch).tint(Theme.primary).labelsHidden()
        }
    }

    private func textRow(_ symbol: String, _ title: String, _ placeholder: String, _ value: Binding<String>) -> some View {
        SettingsRow(symbol: symbol, tint: Theme.muted, title: title) {
            TextField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
        }
    }
}

private struct EnvironmentEditor: View {
    @Binding var vars: [EnvVar]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Environment variables").font(Theme.font(14, .medium))
                Spacer()
                Button {
                    vars.append(EnvVar(key: "", value: ""))
                } label: { Label("Add", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(prominent: false))
            }
            ForEach($vars) { $v in
                HStack {
                    TextField("KEY", text: $v.key).textFieldStyle(.roundedBorder).frame(width: 150)
                    Text("=").foregroundStyle(Theme.muted)
                    TextField("value", text: $v.value).textFieldStyle(.roundedBorder)
                    Button { vars.removeAll { $0.id == v.id } } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }
}
