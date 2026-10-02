import SwiftUI

/// Blurred, desaturated art of the highlighted game behind the library (GameNative `LibraryDynamicBackdrop`).
struct Backdrop: View {
    var url: URL?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.background, Theme.surface, Theme.background],
                           startPoint: .top, endPoint: .bottom)
            if let url {
                GeometryReader { geo in
                    RemoteImage(url: url, fallback: nil) { Color.clear }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                    .scaleEffect(1.06)
                    .blur(radius: 14)
                    .saturation(0.25)
                    .opacity(0.38)
                    .id(url)
                    .transition(.opacity.animation(.easeInOut(duration: 0.5)))
            }
            LinearGradient(stops: [
                .init(color: .black.opacity(0.48), location: 0),
                .init(color: .black.opacity(0.48), location: 0.4),
                .init(color: .black.opacity(0.62), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
    }
}
