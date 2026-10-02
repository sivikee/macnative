import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Namespace private var pill

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            header
            sectionTabs.padding(.horizontal, 24).padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 16) {
                    switch app.settingsSection {
                    case .defaults:
                        Text("New games start with these settings. Each game can override them from its page.")
                            .font(Theme.font(13)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        GameConfigForm(config: $app.settings.defaultConfig, showsEngine: false)
                    case .engines: EnginesSection()
                    case .accounts: AccountsSection()
                    case .system: SystemSection()
                    case .about: AboutSection()
                    }
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 24).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .background(
            LinearGradient(colors: [Theme.surface, Theme.background], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 14) {
            CircleIconButton(symbol: "chevron.left") { app.route = .library }
                .help("Back (B / Circle / Esc)")
            ZStack {
                Circle().fill(RadialGradient(colors: [Theme.tertiary.opacity(0.2), .clear], center: .center, startRadius: 0, endRadius: 24))
                Image(systemName: "gearshape.fill").font(.system(size: 22)).foregroundStyle(Theme.tertiary.opacity(0.7))
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(Theme.font(26, .bold))
                Text("Engines, accounts and defaults — no Wine config files needed.")
                    .font(Theme.font(13)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
    }

    private var sectionTabs: some View {
        HStack(spacing: 8) {
            ForEach(SettingsSection.allCases) { s in
                let selected = app.settingsSection == s
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { app.settingsSection = s }
                } label: {
                    Label(s.title, systemImage: s.symbol)
                        .font(Theme.font(14, selected ? .bold : .medium))
                        .foregroundStyle(Theme.foreground.opacity(selected ? 1 : 0.65))
                        .padding(.horizontal, 18).frame(minHeight: 38)
                        .background {
                            if selected {
                                Capsule().fill(Theme.primary).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.secondary.opacity(0.35)))
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Engines

private struct EnginesSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        SettingsCard(title: "Installed engines", subtitle: "Wine builds live inside MacNative's data folder") {
            if app.engines.regularEngines.isEmpty {
                SettingsRow(symbol: "exclamationmark.triangle.fill", tint: Theme.warning, title: "No engine installed",
                            subtitle: "Download one below to start playing.") { EmptyView() }
            }
            ForEach(app.engines.regularEngines) { e in
                let isDefault = (app.settings.defaultEngineID ?? app.engines.regularEngines.first?.id) == e.id
                SettingsRow(symbol: "wineglass.fill", tint: Theme.pink, title: e.name,
                            subtitle: isDefault ? "Default engine" : "Installed \(e.installedAt.formatted(date: .abbreviated, time: .omitted))") {
                    if !isDefault {
                        Button("Make default") { app.settings.defaultEngineID = e.id }
                            .buttonStyle(PillButtonStyle(prominent: false))
                    }
                    Button {
                        try? app.engines.uninstall(e)
                        if app.settings.defaultEngineID == e.id { app.settings.defaultEngineID = app.engines.regularEngines.first?.id }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(PillButtonStyle(color: Theme.destructive))
                }
            }
        }

        SettingsCard(title: "Available", subtitle: app.engines.catalogError ?? "Upstream Wine builds for macOS by Gcenx, with MoltenVK bundled") {
            if app.engines.isLoadingCatalog {
                ProgressView().controlSize(.small).padding(20)
            }
            ForEach(app.engines.available) { r in
                let installed = app.engines.installed.contains { $0.id == r.id }
                let activity = app.activities["engine:\(r.id)"]
                SettingsRow(symbol: r.flavor == "staging" ? "star.fill" : "hammer.fill",
                            tint: r.flavor == "staging" ? Theme.warning : Theme.purple,
                            title: r.name + (r.id == app.engines.recommended.id ? "  ·  Recommended" : ""),
                            subtitle: activity?.detail ?? Format.bytes(r.sizeBytes)) {
                    if let activity {
                        GradientProgressBar(progress: activity.progress).frame(width: 140)
                        CancelJobButton(jobID: "engine:\(r.id)")
                    } else if installed {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.statusInstalled)
                    } else {
                        Button("Download") { app.installEngine(r) }
                            .buttonStyle(PillButtonStyle())
                    }
                }
            }
        }

        SettingsCard(title: "Translation layers", subtitle: "Downloaded automatically the first time a game needs them") {
            component(EngineManager.dxvk, symbol: "cube.transparent", tint: Theme.tertiary,
                      text: "DirectX 10/11 → Vulkan, via MoltenVK")
            component(EngineManager.dxmt, symbol: "cube.fill", tint: Theme.primaryLight,
                      text: "DirectX 10/11 → Metal (experimental)")
        }

        D3DMetalCard()
    }

    private func component(_ c: ComponentRelease, symbol: String, tint: Color, text: String) -> some View {
        SettingsRow(symbol: symbol, tint: tint, title: "\(c.name) \(c.version)", subtitle: text) {
            if app.engines.isComponentInstalled(c) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.statusInstalled)
            } else {
                Text("On demand").font(Theme.font(12)).foregroundStyle(Theme.muted)
            }
        }
    }
}

// MARK: - DirectX 12

/// D3DMetal: the GPTK engine (auto-downloaded, includes D3DMetal) plus an optional newer D3DMetal from Apple.
private struct D3DMetalCard: View {
    @Environment(AppState.self) private var app
    static let appleDownloads = URL(string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit")!

    var body: some View {
        @Bindable var app = app
        let release = app.engines.gptkRelease
        let engine = app.engines.gptkEngine
        let engineJob = "engine:\(release.id)"
        let importJob = "d3dmetal-import"

        SettingsCard(title: "DirectX 12 (D3DMetal)",
                     subtitle: "Apple's translation layer. Pick “D3DMetal” as a game's graphics backend to use it") {
            SettingsRow(symbol: "cpu.fill", tint: Theme.primaryLight,
                        title: engine?.name ?? release.name,
                        subtitle: app.activities[engineJob]?.detail ?? (engine != nil
                            ? "Installed · Wine build from Gcenx with D3DMetal included"
                            : "Not downloaded · \(Format.bytes(release.sizeBytes)). Downloads automatically the first time a D3DMetal game launches.")) {
                if let a = app.activities[engineJob] {
                    GradientProgressBar(progress: a.progress).frame(width: 140)
                    CancelJobButton(jobID: engineJob)
                } else if let engine {
                    Button { try? app.engines.uninstall(engine) } label: { Image(systemName: "trash") }
                        .buttonStyle(PillButtonStyle(color: Theme.destructive))
                } else {
                    Button("Download") { app.installD3DMetalEngine() }.buttonStyle(PillButtonStyle())
                }
            }

            let imported = app.engines.d3dmetalImport
            SettingsRow(symbol: "sparkles", tint: Theme.tertiary,
                        title: imported.map { "D3DMetal \($0.version) from Apple" } ?? "Use a newer D3DMetal (optional)",
                        subtitle: app.activities[importJob]?.detail ?? (imported != nil
                            ? "Layered over the GPTK engine for all D3DMetal games."
                            : "Download Apple's Game Porting Toolkit (free Apple ID), then import the .dmg or a folder.")) {
                if app.activities[importJob] != nil {
                    ProgressView().controlSize(.small)
                    CancelJobButton(jobID: importJob)
                } else if imported != nil {
                    Toggle("", isOn: $app.settings.useImportedD3DMetal).toggleStyle(.switch).tint(Theme.primary).labelsHidden()
                        .help("Use this D3DMetal instead of the bundled one")
                    Button { app.engines.removeD3DMetalImport() } label: { Image(systemName: "trash") }
                        .buttonStyle(PillButtonStyle(color: Theme.destructive))
                } else {
                    Button("Get from Apple") { NSWorkspace.shared.open(Self.appleDownloads) }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    Button("Import…", action: chooseImport).buttonStyle(PillButtonStyle())
                }
            }
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.diskImage, .folder]
        panel.message = "Choose Apple's Game Porting Toolkit .dmg, or a folder containing redist/lib"
        if panel.runModal() == .OK, let url = panel.url { app.importD3DMetal(from: url) }
    }
}

// MARK: - Accounts

private struct AccountsSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        SettingsCard(title: "Steam", subtitle: "Runs the official Windows Steam client in its own prefix") {
            let activity = app.activities["steam-client"]
            SettingsRow(symbol: "cloud.fill", tint: Theme.statusAvailable,
                        title: SteamService.isClientInstalled ? "Steam client installed" : "Steam client not installed",
                        subtitle: activity?.detail ?? (SteamService.isClientInstalled
                            ? "Sign in inside Steam once; installed and owned games appear in your library."
                            : "Downloads the official installer from Valve (~2 MB, then Steam updates itself).")) {
                if let activity {
                    GradientProgressBar(progress: activity.progress).frame(width: 140)
                    CancelJobButton(jobID: "steam-client")
                } else if SteamService.isClientInstalled {
                    Button("Open Steam") { Task { do { try await app.openSteam(arguments: []) } catch { app.report(error) } } }
                        .buttonStyle(PillButtonStyle(color: Theme.statusAvailable))
                    Button("Rescan") { Task { await app.syncSteam() } }
                        .buttonStyle(PillButtonStyle(prominent: false))
                } else {
                    Button("Set up Steam") { app.installSteamClient() }
                        .buttonStyle(PillButtonStyle(color: Theme.statusAvailable))
                }
            }
        }

        SettingsCard(title: "GOG", subtitle: "DRM-free games install directly, no client needed") {
            SettingsRow(symbol: "g.circle.fill", tint: Theme.purple,
                        title: app.isGOGLoggedIn ? "Signed in" : "Not signed in",
                        subtitle: app.isGOGLoggedIn
                            ? "\(app.games.filter { $0.source == .gog }.count) Windows games in your library"
                            : "Sign in with your GOG account to see your games.") {
                if app.isGOGLoggedIn {
                    Button("Sync") { Task { await app.syncGOG() } }.buttonStyle(PillButtonStyle(prominent: false))
                    Button("Sign out") { app.logoutGOG() }.buttonStyle(PillButtonStyle(color: Theme.destructive))
                } else {
                    Button("Sign in") { app.showGOGLogin = true }.buttonStyle(PillButtonStyle())
                }
            }
        }
    }
}

// MARK: - System

private struct SystemSection: View {
    @Environment(AppState.self) private var app
    @State private var confirmErase = false
    @State private var dataSize: Int64?

    var body: some View {
        @Bindable var app = app
        SettingsCard(title: "Requirements") {
            SettingsRow(symbol: "memorychip", tint: app.rosettaInstalled ? Theme.success : Theme.warning,
                        title: "Rosetta 2",
                        subtitle: app.rosettaInstalled ? "Installed" : "Required to run Windows games on Apple Silicon") {
                if !app.rosettaInstalled {
                    Button("Install") { Task { await app.installRosetta() } }.buttonStyle(PillButtonStyle())
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.statusInstalled)
                }
            }
            SettingsRow(symbol: "gamecontroller.fill", tint: Theme.tertiary, title: "Controller",
                        subtitle: app.controllerName.map { "\($0) connected" }
                            ?? "Xbox, PlayStation, Switch Pro and MFi controllers work in menus and games") { EmptyView() }
        }

        SettingsCard(title: "Storage", subtitle: "Everything MacNative creates lives in this one folder") {
            SettingsRow(symbol: "externaldrive.fill", tint: Theme.statusAvailable, title: "Data folder", subtitle: Paths.root.path) {
                Button("Reveal") { NSWorkspace.shared.open(Paths.root) }.buttonStyle(PillButtonStyle(prominent: false))
            }
            SettingsRow(symbol: "shippingbox", tint: Theme.purple, title: "Keep GOG installers",
                        subtitle: "Keep the downloaded setup files after installing") {
                Toggle("", isOn: $app.settings.keepInstallers).toggleStyle(.switch).tint(Theme.primary).labelsHidden()
            }
        }

        SettingsCard(title: "Danger zone") {
            SettingsRow(symbol: "trash.fill", tint: Theme.danger, title: "Erase everything",
                        subtitle: app.activities["erase"]?.detail
                            ?? "Deletes all games, saves inside prefixes, engines, downloads, accounts and settings"
                            + (dataSize.map { " (\(Format.bytes($0)))" } ?? "") + ".") {
                if app.activities["erase"] != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Erase…") { confirmErase = true }
                        .buttonStyle(PillButtonStyle(color: Theme.danger))
                }
            }
        }
        .task {
            let items = Paths.ownedItems
            dataSize = await Task.detached { items.reduce(0) { $0 + Format.directorySize($1) } }.value
        }
        .alert("Erase everything?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) {
                Task { await app.eraseEverything(); dataSize = 0 }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops any running games and permanently deletes every installed game, its saves, all Wine engines, downloads, your GOG sign-in and all settings. Steam cloud saves are not affected. This can't be undone.")
        }

        SettingsCard(title: "Debug") {
            SettingsRow(symbol: "ladybug.fill", tint: Theme.danger, title: "Verbose Wine logging",
                        subtitle: "Write Wine errors and module loads to each game's log") {
                Toggle("", isOn: $app.settings.verboseWineLogging).toggleStyle(.switch).tint(Theme.primary).labelsHidden()
            }
            SettingsRow(symbol: "doc.text", tint: Theme.muted, title: "Logs folder") {
                Button("Open") { NSWorkspace.shared.open(Paths.logs) }.buttonStyle(PillButtonStyle(prominent: false))
            }
            SettingsRow(symbol: "arrow.counterclockwise", tint: Theme.warning, title: "Run setup again") {
                Button("Open") { app.showSetup = true }.buttonStyle(PillButtonStyle(prominent: false))
            }
        }
    }
}

// MARK: - About

private struct AboutSection: View {
    var body: some View {
        SettingsCard(title: "MacNative", subtitle: "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · GPL-3.0") {
            credit("GameNative", "Design language and container-settings model", "https://github.com/utkarshdalal/GameNative")
            credit("Wine", "Windows compatibility layer (LGPL)", "https://www.winehq.org")
            credit("Gcenx macOS Wine builds", "Wine packaged for macOS with MoltenVK", "https://github.com/Gcenx/macOS_Wine_builds")
            credit("DXVK-macOS", "Direct3D 10/11 → Vulkan (zlib)", "https://github.com/Gcenx/DXVK-macOS")
            credit("DXMT", "Direct3D 10/11 → Metal (zlib)", "https://github.com/3Shain/dxmt")
            credit("MoltenVK", "Vulkan → Metal (Apache 2.0)", "https://github.com/KhronosGroup/MoltenVK")
            credit("Bricolage Grotesque", "Typeface (SIL OFL 1.1)", "https://github.com/ateliertriay/bricolage")
        }
    }

    private func credit(_ name: String, _ text: String, _ url: String) -> some View {
        SettingsRow(symbol: "heart.fill", tint: Theme.pink, title: name, subtitle: text) {
            Link(destination: URL(string: url)!) { Image(systemName: "arrow.up.right.square") }
        }
    }
}
