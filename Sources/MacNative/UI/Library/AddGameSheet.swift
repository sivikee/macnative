import SwiftUI
import UniformTypeIdentifiers

/// Adds a Windows game that isn't from Steam or GOG: pick its .exe, give it a name.
struct AddGameSheet: View {
    @Environment(AppState.self) private var app
    @State private var executable: URL?
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add a Windows game").font(Theme.font(22, .bold))
            Text("Pick the game's .exe. It gets its own Wine prefix and the default settings, which you can change later.")
                .font(Theme.font(13)).foregroundStyle(Theme.muted)

            HStack {
                Image(systemName: "doc.fill").foregroundStyle(Theme.tertiary)
                Text(executable?.path ?? "No file selected").font(Theme.font(13)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…", action: choose).buttonStyle(PillButtonStyle(prominent: false))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.secondary.opacity(0.4)))

            TextField("Name", text: $title).textFieldStyle(.roundedBorder).font(Theme.font(14))

            HStack {
                Spacer()
                Button("Cancel") { app.showAddGame = false }.buttonStyle(PillButtonStyle(prominent: false))
                Button("Add to library") {
                    guard let executable else { return }
                    app.addCustomGame(executable: executable, title: title.isEmpty ? executable.deletingPathExtension().lastPathComponent : title)
                    app.showAddGame = false
                    app.filter = .custom
                }
                .buttonStyle(PillButtonStyle())
                .disabled(executable == nil)
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(Theme.surfaceElevated)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .item, UTType(filenameExtension: "msi") ?? .item]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the game's Windows executable"
        if panel.runModal() == .OK, let url = panel.url {
            executable = url
            if title.isEmpty {
                title = url.deletingLastPathComponent().lastPathComponent
            }
        }
    }
}
