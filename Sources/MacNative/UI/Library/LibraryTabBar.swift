import SwiftUI

/// Top bar: settings, sliding-pill tabs, search, add. Swaps to a search field when searching.
struct LibraryTabBar: View {
    @Environment(AppState.self) private var app
    @Namespace private var pill
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 8) {
            if app.isSearching {
                searchField
            } else {
                CircleIconButton(symbol: "slider.horizontal.3") { app.route = .settings }
                    .help("Settings (Start / Options)")
                tabs
                CircleIconButton(symbol: "magnifyingglass") { app.isSearching = true }
                    .help("Search (Y / Triangle)")
                CircleIconButton(symbol: "plus") { app.showAddGame = true }
                    .help("Add a game")
                CircleIconButton(symbol: "arrow.clockwise") { Task { await app.refreshLibraries() } }
                    .help("Refresh libraries")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .background(
            LinearGradient(stops: [
                .init(color: Theme.surface.opacity(0.98), location: 0),
                .init(color: Theme.surface.opacity(0.85), location: 0.6),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        )
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            shoulderHint("LB")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LibraryFilter.allCases) { f in tab(f) }
                }
            }
            shoulderHint("RB")
        }
        .padding(4)
        .background(
            Capsule().fill(LinearGradient(
                colors: [Theme.secondary.opacity(0.3), Theme.secondary.opacity(0.4), Theme.secondary.opacity(0.3)],
                startPoint: .leading, endPoint: .trailing))
        )
        .frame(maxWidth: .infinity)
    }

    private func tab(_ f: LibraryFilter) -> some View {
        let selected = app.filter == f
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                app.filter = f
                app.focusedIndex = 0
            }
        } label: {
            HStack(spacing: 4) {
                if let s = f.symbol { Image(systemName: s).font(.system(size: 13)) }
                Text(f.title).font(Theme.font(14, selected ? .bold : .medium))
            }
            .foregroundStyle(Theme.foreground.opacity(selected ? 1 : 0.65))
            .padding(.horizontal, 20)
            .frame(minHeight: 40)
            .background {
                if selected {
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.primary, Theme.primary.opacity(0.9)],
                                             startPoint: .leading, endPoint: .trailing))
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: app.filter)
    }

    private func shoulderHint(_ label: String) -> some View {
        Text(label)
            .font(Theme.font(10, .bold))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).stroke(Theme.muted.opacity(0.4)))
            .opacity(app.controllerName == nil ? 0 : 1)
            .frame(width: app.controllerName == nil ? 0 : nil)
    }

    private var searchField: some View {
        @Bindable var app = app
        return HStack(spacing: 12) {
            Button {
                app.search = ""
                app.isSearching = false
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.secondary.opacity(0.5)))
            }
            .buttonStyle(.plain)
            Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(Theme.muted)
            TextField("Search your library", text: $app.search)
                .textFieldStyle(.plain)
                .font(Theme.font(16))
                .focused($searchFocused)
                .onSubmit { searchFocused = false; app.isSearching = !app.search.isEmpty; app.focusedIndex = 0 }
            if !app.search.isEmpty {
                Button { app.search = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.secondary.opacity(0.5)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(
            Capsule().fill(LinearGradient(
                colors: [Theme.secondary.opacity(0.5), Theme.secondary.opacity(0.6), Theme.secondary.opacity(0.5)],
                startPoint: .leading, endPoint: .trailing))
        )
        .overlay(Capsule().strokeBorder(Theme.primary.opacity(searchFocused ? 0.5 : 0), lineWidth: 2))
        .onAppear { searchFocused = true }
    }
}
