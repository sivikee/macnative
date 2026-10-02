import Foundation

/// Console-style navigation for controllers and the keyboard.
extension AppState {
    func handle(_ action: NavAction) -> Bool {
        controllerOrKeyboardActive = true
        if showSetup || showAddGame || showGOGLogin {
            if action == .back, !showSetup { showAddGame = false; showGOGLogin = false; return true }
            return false
        }
        switch route {
        case .library: return handleLibrary(action)
        case let .game(id): return handleDetail(action, id)
        case .settings: return handleSettings(action)
        }
    }

    private func handleLibrary(_ action: NavAction) -> Bool {
        let count = visibleGames.count
        let cols = max(gridColumns, 1)
        switch action {
        case .left: focusedIndex = max(focusedIndex - 1, 0)
        case .right: focusedIndex = min(focusedIndex + 1, max(count - 1, 0))
        case .up: if focusedIndex >= cols { focusedIndex -= cols }
        case .down: if focusedIndex + cols < count { focusedIndex += cols } else if focusedIndex / cols < (count - 1) / cols { focusedIndex = count - 1 }
        case .confirm:
            guard let g = focusedGame else { return false }
            detailFocus = 0
            route = .game(g.id)
        case .back:
            if isSearching || !search.isEmpty { search = ""; isSearching = false } else { return false }
        case .previousTab, .nextTab:
            let all = LibraryFilter.allCases
            let i = all.firstIndex(of: filter) ?? 0
            let next = action == .nextTab ? (i + 1) % all.count : (i - 1 + all.count) % all.count
            filter = all[next]
            focusedIndex = 0
        case .search: isSearching = true
        case .secondary:
            guard let g = focusedGame else { return false }
            update(g.id) { $0.isFavorite.toggle() }
        case .menu: route = .settings
        }
        return true
    }

    /// Detail buttons, left to right: primary action, favorite, game settings.
    static let detailButtonCount = 3

    private func handleDetail(_ action: NavAction, _ id: String) -> Bool {
        if showGameSettings {
            if action == .back { showGameSettings = false; return true }
            return false
        }
        guard let game = game(id) else { route = .library; return true }
        switch action {
        case .left: detailFocus = max(detailFocus - 1, 0)
        case .right: detailFocus = min(detailFocus + 1, Self.detailButtonCount - 1)
        case .confirm:
            switch detailFocus {
            case 0: Task { await primaryAction(game) }
            case 1: update(id) { $0.isFavorite.toggle() }
            default: showGameSettings = true
            }
        case .back: route = .library
        case .secondary: update(id) { $0.isFavorite.toggle() }
        case .menu: showGameSettings = true
        default: return false
        }
        return true
    }

    private func handleSettings(_ action: NavAction) -> Bool {
        switch action {
        case .back, .menu: route = .library
        case .previousTab, .nextTab:
            let all = SettingsSection.allCases
            let i = all.firstIndex(of: settingsSection) ?? 0
            settingsSection = all[action == .nextTab ? (i + 1) % all.count : (i - 1 + all.count) % all.count]
        default: return false
        }
        return true
    }

    func primaryAction(_ game: Game) async {
        if isRunning(game) { await stop(game) }
        else if game.isInstalled { await play(game) }
        else { await install(game) }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case defaults, engines, accounts, system, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .defaults: "Game Defaults"
        case .engines: "Engines"
        case .accounts: "Accounts"
        case .system: "System"
        case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .defaults: "slider.horizontal.3"
        case .engines: "cpu"
        case .accounts: "person.crop.circle"
        case .system: "gearshape.2"
        case .about: "info.circle"
        }
    }
}
