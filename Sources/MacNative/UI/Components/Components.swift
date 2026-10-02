import SwiftUI

/// Rotating magenta/cyan gradient outline used for keyboard/controller focus (GameNative `FocusRing`).
struct FocusRing<S: InsettableShape>: View {
    var shape: S
    var active: Bool
    @State private var angle = 0.0

    var body: some View {
        shape
            .strokeBorder(
                AngularGradient(colors: [Theme.primary, Theme.tertiary, Theme.primary],
                                center: .center, angle: .degrees(angle)),
                lineWidth: 2)
            .opacity(active ? 1 : 0)
            .onAppear {
                withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) { angle = 360 }
            }
            .allowsHitTesting(false)
    }
}

/// 44pt round button with a radial fill (GameNative tab-bar icon buttons).
struct CircleIconButton: View {
    var symbol: String
    var size: CGFloat = 44
    var highlighted = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        let on = highlighted || hover
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(Theme.foreground.opacity(on ? 1 : 0.8))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(RadialGradient(
                        colors: on ? [Theme.primary.opacity(0.4), Theme.primary.opacity(0.2)]
                                   : [Theme.secondary.opacity(0.4), Theme.secondary.opacity(0.2)],
                        center: .center, startRadius: 0, endRadius: size / 2)))
                .opacity(on ? 1 : 0.75)
                .scaleEffect(on ? 1.1 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: on)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Capsule progress bar with the cyan → purple → pink brand gradient.
struct GradientProgressBar: View {
    var progress: Double?
    var height: CGFloat = 6
    @State private var phase = 0.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.foreground.opacity(0.15))
                if let progress {
                    Theme.brandGradient
                        .frame(width: geo.size.width)
                        .mask(alignment: .leading) {
                            Capsule().frame(width: max(height, geo.size.width * min(max(progress, 0), 1)))
                        }
                        .animation(.easeOut(duration: 0.25), value: progress)
                } else {
                    // Indeterminate: a sliding segment.
                    Capsule().fill(Theme.brandGradient)
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: (geo.size.width * 1.3) * phase - geo.size.width * 0.3)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

/// Round ✕ button that cancels a running job (download/install).
struct CancelJobButton: View {
    @Environment(AppState.self) private var app
    var jobID: String

    var body: some View {
        if app.canCancel(jobID) {
            Button { app.cancelJob(jobID) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.foreground)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.danger.opacity(0.8)))
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
    }
}

/// Small label/value tile on the game page (GameNative `InfoCard`).
struct InfoCard: View {
    var label: String
    var value: String
    var statusColor: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.font(12, .medium)).foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                if let statusColor { Circle().fill(statusColor).frame(width: 10, height: 10) }
                Text(value).font(Theme.font(16, .semibold))
                    .foregroundStyle(statusColor ?? Theme.foreground)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surfaceHigh))
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

/// Pill with a translucent black background, used over artwork.
struct OverlayPill: View {
    var symbol: String?
    var text: String?
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            if let text { Text(text).font(Theme.font(11, .semibold)) }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.55)))
    }
}

/// Settings group card: radius 20 on the elevated surface (GameNative settings screen).
struct SettingsCard<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(15, .semibold)).foregroundStyle(Theme.primaryLight)
                if let subtitle {
                    Text(subtitle).font(Theme.font(12)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            content
        }
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.surfaceElevated))
    }
}

/// One row in a settings card: tinted icon tile, title/subtitle, trailing control.
struct SettingsRow<Trailing: View>: View {
    var symbol: String
    var tint: Color = Theme.tertiary
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(14, .medium)).foregroundStyle(Theme.foreground)
                if let subtitle {
                    Text(subtitle).font(Theme.font(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }
}

/// Primary/secondary filled buttons in GameNative's style.
struct PillButtonStyle: ButtonStyle {
    var color: Color = Theme.primary
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(13, .semibold))
            .foregroundStyle(Theme.foreground)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(prominent ? color : Theme.foreground.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Artwork loader with the shared on-disk cache configured in `MacNativeApp`.
struct RemoteImage<Placeholder: View>: View {
    var url: URL?
    var fallback: URL?
    @ViewBuilder var placeholder: Placeholder
    @State private var useFallback = false

    var body: some View {
        AsyncImage(url: useFallback ? fallback : url, transaction: .init(animation: .easeOut(duration: 0.3))) { phase in
            switch phase {
            case let .success(image): image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                placeholder.onAppear { if fallback != nil, !useFallback { useFallback = true } }
            default: placeholder
            }
        }
    }
}
