import SwiftUI
import CoreImage.CIFilterBuiltins

/// Native Steam sign-in: account + password (+ Steam Guard), or QR code for the Steam mobile app.
struct SteamLoginView: View {
    @Environment(AppState.self) private var app
    @State private var useQR = false
    @State private var account = ""
    @State private var password = ""
    @State private var code = ""
    @FocusState private var focus: Field?

    private enum Field { case account, password, code }

    var body: some View {
        let steam = app.steam
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "cloud.fill").foregroundStyle(Theme.statusAvailable)
                Text("Sign in to Steam").font(Theme.font(22, .bold))
                Spacer()
                CircleIconButton(symbol: "xmark", size: 32) { close() }
            }
            Text("MacNative talks to Steam directly, like GameNative. Your password goes only to Steam; MacNative keeps a sign-in token in its data folder.")
                .font(Theme.font(12)).foregroundStyle(Theme.muted)

            Picker("", selection: $useQR) {
                Text("Account").tag(false)
                Text("QR code").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: useQR) { _, qr in qr ? steam.startQR() : steam.cancelLogin() }

            Group {
                switch steam.loginStep {
                case let .needsCode(email, phone, error):
                    guardCode(email: email, phone: phone, error: error)
                case .waitingForPhone:
                    status("iphone", "Approve the sign-in in the Steam mobile app…")
                case let .qr(url):
                    qrCode(url)
                case let .working(text):
                    status(nil, text)
                case let .failed(message):
                    VStack(alignment: .leading, spacing: 14) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning).font(Theme.font(13))
                        if useQR { Button("Try again") { steam.startQR() }.buttonStyle(PillButtonStyle()) }
                        else { credentials }
                    }
                case .idle:
                    if useQR { status(nil, "Preparing QR code…") } else { credentials }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .top)
        }
        .padding(28)
        .frame(width: 460)
        .background(Theme.surfaceElevated)
        .onChange(of: steam.isLoggedIn) { _, loggedIn in if loggedIn { app.showSteamLogin = false } }
        .onAppear { focus = .account }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Steam account name", text: $account)
                .textFieldStyle(.roundedBorder).textContentType(.username).focused($focus, equals: .account)
                .onSubmit { focus = .password }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder).textContentType(.password).focused($focus, equals: .password)
                .onSubmit(signIn)
            HStack {
                Spacer()
                Button("Sign in", action: signIn).buttonStyle(PillButtonStyle(color: Theme.statusAvailable))
                    .disabled(account.isEmpty || password.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func guardCode(email: Bool, phone: Bool, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(email ? "Enter the code Steam emailed you" : "Enter the code from your Steam Guard mobile authenticator")
                .font(Theme.font(14, .medium))
            if phone {
                Text("…or approve the sign-in in the Steam mobile app.").font(Theme.font(12)).foregroundStyle(Theme.muted)
            }
            TextField("Code", text: $code)
                .textFieldStyle(.roundedBorder).font(.system(size: 20, weight: .semibold, design: .monospaced))
                .focused($focus, equals: .code)
                .onSubmit { app.steam.submitCode(code) }
                .onAppear { focus = .code }
            if let error { Text(error).font(Theme.font(12)).foregroundStyle(Theme.warning) }
            HStack {
                Spacer()
                Button("Continue") { app.steam.submitCode(code) }
                    .buttonStyle(PillButtonStyle(color: Theme.statusAvailable)).disabled(code.count < 5)
            }
        }
    }

    private func qrCode(_ url: String) -> some View {
        HStack(alignment: .center, spacing: 20) {
            if let image = Self.qrImage(url) {
                Image(nsImage: image).interpolation(.none).resizable()
                    .frame(width: 180, height: 180)
                    .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(.white))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Scan with the Steam mobile app").font(Theme.font(15, .semibold))
                Text("Open Steam on your phone → Steam Guard → scan the QR code, then approve.")
                    .font(Theme.font(12)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func status(_ symbol: String?, _ text: String) -> some View {
        HStack(spacing: 12) {
            if let symbol { Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Theme.tertiary) }
            else { ProgressView().controlSize(.small) }
            Text(text).font(Theme.font(14))
        }
        .padding(.top, 20)
    }

    private func signIn() {
        guard !account.isEmpty, !password.isEmpty else { return }
        app.steam.signIn(account: account, password: password)
        password = ""
    }

    private func close() {
        app.steam.cancelLogin()
        app.showSteamLogin = false
    }

    static func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
