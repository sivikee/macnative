import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var app

    private let minCardWidth: CGFloat = 180
    private let spacing: CGFloat = 14
    private let sidePadding: CGFloat = 24

    var body: some View {
        let games = app.visibleGames
        GeometryReader { geo in
            let cols = max(1, Int((geo.size.width - sidePadding * 2 + spacing) / (minCardWidth + spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    if games.isEmpty {
                        emptyState.padding(.top, 160)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: cols),
                                  spacing: spacing + 4) {
                            ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                                GameCard(game: game,
                                         focused: index == app.focusedIndex && app.controllerOrKeyboardActive,
                                         activity: app.activities[game.id],
                                         running: app.isRunning(game),
                                         compat: app.compat.entry(for: game)?.status)
                                    .id(game.id)
                                    .onTapGesture {
                                        app.focusedIndex = index
                                        app.detailFocus = 0
                                        app.route = .game(game.id)
                                    }
                                    .onHover { if $0 { app.focusedIndex = index } }
                            }
                        }
                        .padding(.horizontal, sidePadding)
                        .padding(.top, 84)
                        .padding(.bottom, 72)
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: app.focusedIndex) { _, i in
                    guard games.indices.contains(i) else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(games[i].id, anchor: .center) }
                }
            }
            .onAppear { app.gridColumns = cols }
            .onChange(of: cols) { _, c in app.gridColumns = c }
        }
        .overlay(alignment: .top) { LibraryTabBar() }
        .overlay(alignment: .bottom) { ControllerHints() }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: emptySymbol).font(.system(size: 44)).foregroundStyle(Theme.tertiary.opacity(0.7))
            Text(emptyTitle).font(Theme.font(22, .semibold))
            Text(emptyMessage).font(Theme.font(14)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                if app.filter == .gog || (app.filter == .all && !app.isGOGLoggedIn) {
                    Button("Sign in to GOG") { app.showGOGLogin = true }.buttonStyle(PillButtonStyle())
                }
                if !app.steam.isLoggedIn, app.filter == .steam || app.filter == .all {
                    Button("Sign in to Steam") { app.showSteamLogin = true }
                        .buttonStyle(PillButtonStyle(color: Theme.statusAvailable))
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptySymbol: String {
        app.search.isEmpty ? (app.filter == .favorites ? "heart" : "gamecontroller") : "magnifyingglass"
    }
    private var emptyTitle: String {
        if !app.search.isEmpty { return "No matches" }
        switch app.filter {
        case .favorites: return "No favorites yet"
        case .installed: return "Nothing installed yet"
        default: return "Your library is empty"
        }
    }
    private var emptyMessage: String {
        if !app.search.isEmpty { return "Nothing in this view matches “\(app.search)”." }
        switch app.filter {
        case .favorites: return "Press X / Square or F on a game to favorite it."
        case .steam: return app.steam.isLoggedIn ? "No Windows games found on this Steam account yet." : "Sign in to Steam to see your games. No Steam client needed."
        case .gog: return "Sign in with your GOG account to see your games. They install with no client needed."
        case .custom: return "Add any Windows .exe with the + button."
        default: return "Connect Steam or GOG, or add a Windows game yourself."
        }
    }
}

/// Bottom legend for controller buttons, shown when a controller is connected.
struct ControllerHints: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let name = app.controllerName {
            HStack(spacing: 18) {
                Label(name, systemImage: "gamecontroller.fill").foregroundStyle(Theme.tertiary)
                Spacer()
                hint("A", "Open"); hint("X", "Favorite"); hint("Y", "Search")
                hint("LB/RB", "Tabs"); hint("☰", "Settings")
            }
            .font(Theme.font(12, .medium))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(LinearGradient(colors: [.clear, Theme.background.opacity(0.9)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func hint(_ button: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(button).font(Theme.font(10, .bold)).foregroundStyle(Theme.foreground)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.secondary))
            Text(label)
        }
    }
}
