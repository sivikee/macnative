import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack {
            Backdrop(url: app.route == .library ? (app.focusedGame?.heroURL ?? app.focusedGame?.coverURL) : nil)

            switch app.route {
            case .library: LibraryView().transition(.opacity)
            case let .game(id): GameDetailView(gameID: id).transition(.move(edge: .trailing).combined(with: .opacity))
            case .settings: SettingsView().transition(.opacity)
            }

            if app.showSetup {
                Color.black.opacity(0.6).ignoresSafeArea()
                SetupView().transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.22), value: app.route)
        .animation(.easeOut(duration: 0.22), value: app.showSetup)
        .overlay(alignment: .bottom) { toast }
        .sheet(isPresented: $app.showAddGame) { AddGameSheet() }
        .sheet(isPresented: $app.showGOGLogin) { GOGLoginView() }
        .font(Theme.font(14))
        .foregroundStyle(Theme.foreground)
        .tint(Theme.primary)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1000, minHeight: 680)
    }

    @ViewBuilder private var toast: some View {
        if let message = app.toast {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text(message).font(Theme.font(13)).lineLimit(4)
                Button { app.toast = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .padding(.bottom, 56)
            .frame(maxWidth: 560)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: message) {
                try? await Task.sleep(for: .seconds(8))
                if app.toast == message { app.toast = nil }
            }
        }
    }
}
