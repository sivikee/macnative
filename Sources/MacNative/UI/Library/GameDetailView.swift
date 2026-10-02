import SwiftUI

/// Game page (GameNative `LibraryAppScreen`): parallax hero, title block, action panel, info cards.
struct GameDetailView: View {
    @Environment(AppState.self) private var app
    var gameID: String

    var body: some View {
        if let game = app.game(gameID) {
            content(game)
        }
    }

    private func content(_ game: Game) -> some View {
        @Bindable var app = app
        return ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(game)
                    infoSection(game).padding(20)
                }
            }
            .scrollIndicators(.never)
            .ignoresSafeArea(edges: .top)

            CircleIconButton(symbol: "chevron.left") { app.route = .library }
                .padding(.leading, 16).padding(.top, 12)
                .help("Back (B / Circle / Esc)")
        }
        .background(Theme.background)
        .overlay(alignment: .trailing) {
            if app.showGameSettings {
                SidePanel(title: "\(game.title)", subtitle: "Per-game settings · B / Esc to close") {
                    app.showGameSettings = false
                } content: {
                    GameConfigForm(config: Binding(
                        get: { app.game(gameID)?.config ?? .default },
                        set: { newValue in app.update(gameID) { $0.config = newValue } }),
                        showsEngine: true)
                    gameTools(game)
                }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.25), value: app.showGameSettings)
    }

    // MARK: Hero

    private func hero(_ game: Game) -> some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .scrollView).minY
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: game.heroURL, fallback: game.coverURL) {
                    LinearGradient(colors: [Theme.primary, Theme.primary.opacity(0.2)], startPoint: .top, endPoint: .bottom)
                }
                .frame(width: geo.size.width, height: geo.size.height + max(minY, 0))
                .clipped()
                .offset(y: minY > 0 ? -minY : -minY * 0.5)

                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.3), location: 0.5),
                    .init(color: Theme.background, location: 1),
                ], startPoint: .top, endPoint: .bottom)

                LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0.15), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120).frame(maxHeight: .infinity, alignment: .top)

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.title)
                            .font(Theme.font(34, .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                        Text(subtitle(game)).font(Theme.font(14)).foregroundStyle(.white.opacity(0.85))
                    }
                    actionPanel(game)
                }
                .padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
        .frame(height: 420)
    }

    private func subtitle(_ g: Game) -> String {
        [g.source.displayName, g.developer, g.releaseYear.map(String.init)].compactMap { $0 }.joined(separator: " • ")
    }

    // MARK: Actions

    private func actionPanel(_ game: Game) -> some View {
        HStack(spacing: 12) {
            primaryButton(game)
                .overlay(FocusRing(shape: RoundedRectangle(cornerRadius: 8), active: focus(0)))
            squareButton(game.isFavorite ? "heart.fill" : "heart", tint: game.isFavorite ? Theme.pink : .white, index: 1) {
                app.update(game.id) { $0.isFavorite.toggle() }
            }
            .help("Favorite (X / Square)")
            squareButton("gearshape.fill", index: 2) { app.showGameSettings = true }
                .help("Game settings (Start / Options)")
            Menu {
                gameMenu(game)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.5)))
    }

    @ViewBuilder private func gameMenu(_ game: Game) -> some View {
        Button("Open log") { app.openLog(game) }
        Button("Show prefix in Finder") { app.revealPrefix(game) }
        if game.source == .steam {
            Button("Open Steam") { Task { try? await app.openSteam(arguments: []) } }
        }
        if game.isInstalled || game.source == .custom {
            Divider()
            Button(game.source == .custom ? "Remove from library" : "Uninstall", role: .destructive) {
                Task { await app.uninstall(game) }
            }
        }
    }

    private func focus(_ i: Int) -> Bool { app.controllerOrKeyboardActive && app.detailFocus == i }

    private func primaryButton(_ game: Game) -> some View {
        let activity = app.activities[game.id]
        let running = app.isRunning(game)
        let cancellable = app.canCancel(game.id)
        let (label, symbol, color): (String, String, Color) =
            running ? ("Stop", "stop.fill", Theme.danger)
            : activity != nil ? (activity!.progress.map { "\(Int($0 * 100))%" } ?? "Working…",
                                 cancellable ? "xmark" : "arrow.down", Theme.statusDownloading)
            : game.isInstalled ? ("Play", "play.fill", Theme.statusInstalled)
            : ("Install", "arrow.down.to.line", Theme.statusAvailable)

        return Button {
            Task { await app.primaryAction(game) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18, weight: .bold))
                Text(label).font(Theme.font(17, .bold))
                if let activity {
                    VStack(alignment: .leading, spacing: 4) {
                        GradientProgressBar(progress: activity.progress, height: 4).frame(width: 120)
                        Text(activity.detail).font(Theme.font(11)).lineLimit(1).opacity(0.85)
                    }
                    if cancellable {
                        Text("Cancel").font(Theme.font(13, .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(.black.opacity(0.3)))
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24).frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(activity != nil ? 0.6 : 1)))
        }
        .buttonStyle(.plain)
        // While downloading, the button cancels; it's only inert for jobs that can't be cancelled.
        .disabled(activity != nil && !cancellable)
        .help(cancellable ? "Cancel download (A / Cross)" : "")
    }

    private func squareButton(_ symbol: String, tint: Color = .white, index: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(focus(index) ? 0.2 : 0.1)))
                .overlay(FocusRing(shape: RoundedRectangle(cornerRadius: 8), active: focus(index)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Body

    private func infoSection(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Game information").font(Theme.font(18, .semibold)).padding(.bottom, 4)
            HStack(spacing: 12) {
                InfoCard(label: "Status", value: app.isRunning(game) ? "Running" : game.isInstalled ? "Installed" : "Not installed",
                         statusColor: app.isRunning(game) ? Theme.tertiary : game.isInstalled ? Theme.statusInstalled : Theme.muted)
                InfoCard(label: "Size", value: game.installSizeBytes.map(Format.bytes) ?? "—")
            }
            HStack(spacing: 12) {
                InfoCard(label: "Graphics", value: game.config.graphics.displayName)
                InfoCard(label: "Engine", value: app.engineDescription(for: game.config))
            }
            HStack(spacing: 12) {
                InfoCard(label: "Play time", value: game.playTimeSeconds > 0 ? Format.playTime(game.playTimeSeconds) : "Never played")
                InfoCard(label: "Last played", value: game.lastPlayed.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
            }
            if let dir = game.installDirectory {
                InfoCard(label: "Location", value: dir)
            }
            if game.source == .steam {
                Text("Steam games launch through the Windows Steam client, so Steam overlay, cloud saves and achievements keep working.")
                    .font(Theme.font(12)).foregroundStyle(Theme.muted).padding(.top, 6)
            }
        }
    }

    private func gameTools(_ game: Game) -> some View {
        SettingsCard(title: "Tools") {
            SettingsRow(symbol: "doc.text.magnifyingglass", title: "Wine log", subtitle: "Last run's output") {
                Button("Open") { app.openLog(game) }.buttonStyle(PillButtonStyle(prominent: false))
            }
            SettingsRow(symbol: "folder", title: "Prefix", subtitle: game.prefixName) {
                Button("Reveal") { app.revealPrefix(game) }.buttonStyle(PillButtonStyle(prominent: false))
            }
            SettingsRow(symbol: "arrow.uturn.backward", tint: Theme.warning, title: "Reset to defaults") {
                Button("Reset") { app.update(game.id) { $0.config = app.settings.defaultConfig } }
                    .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
    }
}

/// Panel sliding in from the right over a scrim (GameNative `GameOptionsPanel`).
struct SidePanel<Content: View>: View {
    var title: String
    var subtitle: String?
    var onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            Color.black.opacity(0.5).onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(Theme.font(20, .bold)).lineLimit(1)
                        if let subtitle { Text(subtitle).font(Theme.font(12)).foregroundStyle(Theme.muted) }
                    }
                    Spacer()
                    CircleIconButton(symbol: "xmark", size: 36, action: onClose)
                }
                .padding(20)
                ScrollView {
                    VStack(spacing: 16) { content }.padding(.horizontal, 16).padding(.bottom, 24)
                }
            }
            .frame(width: 460)
            .background(
                LinearGradient(colors: [Theme.surface.opacity(0.97), Theme.background.opacity(0.99)],
                               startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea())
        }
    }
}
