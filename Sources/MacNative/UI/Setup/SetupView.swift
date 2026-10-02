import SwiftUI

/// First-run checklist: Rosetta → Wine engine → stores. Each step is one button.
struct SetupView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let engineReady = !app.engines.installed.isEmpty
        let recommended = app.engines.recommended
        let engineActivity = app.activities["engine:\(recommended.id)"]

        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to MacNative").font(Theme.font(32, .bold))
                    .foregroundStyle(Theme.brandGradient)
                Text("Three quick steps and your Windows games are ready to play. Everything is stored in one folder.")
                    .font(Theme.font(14)).foregroundStyle(Theme.muted)
            }

            step(1, "Rosetta 2", "Apple's translator for Intel apps. Wine needs it on Apple Silicon.",
                 done: app.rosettaInstalled, activity: app.activities["rosetta"], jobID: "rosetta") {
                Button("Install Rosetta") { Task { await app.installRosetta() } }.buttonStyle(PillButtonStyle())
            }

            step(2, "Wine engine", "\(recommended.name) · \(Format.bytes(recommended.sizeBytes)). Includes MoltenVK for Vulkan/DXVK.",
                 done: engineReady, activity: engineActivity, jobID: "engine:\(recommended.id)") {
                Button("Download") { app.installEngine(recommended) }.buttonStyle(PillButtonStyle())
            }

            step(3, "Connect your stores", "Optional — you can do this later in Settings → Accounts.",
                 done: app.isGOGLoggedIn || SteamService.isClientInstalled, activity: app.activities["steam-client"], jobID: "steam-client") {
                HStack {
                    Button("GOG") { app.showGOGLogin = true }.buttonStyle(PillButtonStyle(color: Theme.purple))
                    Button("Steam") { app.installSteamClient() }
                        .buttonStyle(PillButtonStyle(color: Theme.statusAvailable))
                        .disabled(!engineReady || !app.rosettaInstalled)
                }
            }

            HStack {
                Spacer()
                Button(engineReady && app.rosettaInstalled ? "Start playing" : "Skip for now") {
                    app.settings.hasCompletedSetup = true
                    app.showSetup = false
                }
                .buttonStyle(PillButtonStyle(color: engineReady && app.rosettaInstalled ? Theme.statusInstalled : Theme.secondary))
            }
        }
        .padding(32)
        .frame(width: 640)
        .background(RoundedRectangle(cornerRadius: 24).fill(Theme.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.border.opacity(0.6)))
        .shadow(color: Theme.primary.opacity(0.25), radius: 40)
    }

    private func step<Action: View>(_ n: Int, _ title: String, _ text: String, done: Bool, activity: Activity?, jobID: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(done ? Theme.statusInstalled.opacity(0.2) : Theme.primary.opacity(0.2))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.statusInstalled)
                } else {
                    Text("\(n)").font(Theme.font(16, .bold)).foregroundStyle(Theme.primaryLight)
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.font(16, .semibold))
                Text(activity?.detail ?? text).font(Theme.font(12)).foregroundStyle(Theme.muted)
                if let activity { GradientProgressBar(progress: activity.progress).padding(.top, 4) }
            }
            Spacer()
            if activity != nil { CancelJobButton(jobID: jobID) }
            else if !done { action() }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.secondary.opacity(0.25)))
    }
}
