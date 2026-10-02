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
        .overlay(alignment: .top) { UpdateBanner().padding(.top, 70) }
        .sheet(isPresented: $app.showAddGame) { AddGameSheet() }
        .sheet(isPresented: $app.showGOGLogin) { GOGLoginView() }
        .sheet(isPresented: $app.showSteamLogin) { SteamLoginView() }
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

/// "A new version is available" banner with one-click update.
private struct UpdateBanner: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.updater.showBanner, let release = app.updater.available {
            let activity = app.activities["update"]
            HStack(spacing: 14) {
                if let mark = Theme.logoMark {
                    Image(nsImage: mark).resizable().frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacNative \(release.version) is available").font(Theme.font(14, .semibold))
                    Text(activity?.detail ?? "You have \(app.updater.currentVersion). The update installs and relaunches in a few seconds.")
                        .font(Theme.font(12)).foregroundStyle(Theme.muted)
                }
                if let activity {
                    GradientProgressBar(progress: activity.progress).frame(width: 120)
                    CancelJobButton(jobID: "update")
                } else {
                    Button("Release notes") { NSWorkspace.shared.open(release.notesURL) }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    Button("Update now") { app.installUpdate() }.buttonStyle(PillButtonStyle())
                    Button { app.updater.dismissedVersion = release.version } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Later")
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.primary.opacity(0.5)))
            .shadow(color: Theme.primary.opacity(0.25), radius: 20)
            .frame(maxWidth: 720)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
