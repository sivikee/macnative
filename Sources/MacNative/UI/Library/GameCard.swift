import SwiftUI

/// 2:3 capsule card (GameNative `LibraryGridCard`): artwork, bottom gradient with title,
/// source icon, install/running badges, glow + focus ring when highlighted.
struct GameCard: View {
    var game: Game
    var focused: Bool
    var activity: Activity?
    var running: Bool
    @State private var hover = false

    var body: some View {
        let on = focused || hover
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: game.coverURL, fallback: game.heroURL) { placeholder }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .frame(height: 80)
                .frame(maxHeight: .infinity, alignment: .bottom)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Text(game.title)
                        .font(Theme.font(13, .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if running {
                        statusChip("play.fill", Theme.tertiary)
                    } else if game.isInstalled {
                        statusChip("checkmark", Theme.statusInstalled)
                    }
                }
                if let activity {
                    GradientProgressBar(progress: activity.progress, height: 4)
                } else if game.playTimeSeconds > 60 {
                    Text(Format.playTime(game.playTimeSeconds))
                        .font(Theme.font(11, .medium)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: game.source.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.6), radius: 3)
                .padding(10)
        }
        .overlay(alignment: .topLeading) {
            if game.isFavorite { OverlayPill(symbol: "heart.fill", tint: Theme.pink).padding(8) }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(shape)
        .overlay(FocusRing(shape: shape, active: focused))
        .background {
            // Soft magenta glow behind the highlighted card.
            shape.fill(Theme.primary.opacity(on ? 0.45 : 0)).blur(radius: 22)
        }
        .scaleEffect(on ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
        .onHover { hover = $0 }
        .contentShape(shape)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Theme.surfaceElevated, Theme.secondary], startPoint: .top, endPoint: .bottom)
            Image(systemName: "gamecontroller.fill").font(.system(size: 32)).foregroundStyle(Theme.muted.opacity(0.5))
        }
    }

    private func statusChip(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 20, height: 20)
            .background(Circle().fill(.black.opacity(0.5)))
    }
}
