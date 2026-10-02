import SwiftUI
import CoreText
import AppKit

/// Visual language ported from GameNative (dark zinc base, magenta primary, cyan tertiary,
/// Bricolage Grotesque). Values mirror GameNative's `ui/theme/Color.kt`.
enum Theme {
    static let background = Color(hex: 0x09090B)
    static let surface = Color(hex: 0x12121A)
    static let surfaceElevated = Color(hex: 0x1A1A24)
    static let surfaceHigh = Color(hex: 0x1F1F23)
    static let secondary = Color(hex: 0x27272A)
    static let border = Color(hex: 0x3A3A4A)

    static let foreground = Color(hex: 0xFAFAFA)
    static let muted = Color(hex: 0x94969C)

    static let primary = Color(hex: 0xA21CAF)
    static let primaryLight = Color(hex: 0xE879F9)
    static let tertiary = Color(hex: 0x00D4FF)
    static let purple = Color(hex: 0x8B5CF6)
    static let pink = Color(hex: 0xEC4899)

    static let success = Color(hex: 0x10B981)
    static let warning = Color(hex: 0xF59E0B)
    static let danger = Color(hex: 0xEF4444)
    static let destructive = Color(hex: 0x7F1D1D)

    static let statusInstalled = Color(hex: 0x4CAF50)
    static let statusDownloading = Color(hex: 0x00BCD4)
    static let statusAvailable = Color(hex: 0x2196F3)

    static let brandGradient = LinearGradient(
        colors: [tertiary, purple, pink], startPoint: .leading, endPoint: .trailing)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold: name = "BricolageGrotesque-Bold"
        case .heavy, .black: name = "BricolageGrotesque-ExtraBold"
        case .semibold: name = "BricolageGrotesque-SemiBold"
        case .medium: name = "BricolageGrotesque-Medium"
        default: name = "BricolageGrotesque-Regular"
        }
        return .custom(name, size: size)
    }

    /// Packaged app: Contents/Resources/<folder>. `swift run`: SwiftPM's resource bundle.
    static func resourceFolder(_ name: String) -> URL? {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent(name)
        return packaged.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.module.url(forResource: name, withExtension: nil)
    }

    static let logoMark: NSImage? = resourceFolder("Logo")
        .flatMap { NSImage(contentsOf: $0.appendingPathComponent("macnative-mark-256.png")) }

    /// Registers the bundled fonts for this process only (nothing is installed system-wide).
    static func registerFonts() {
        guard let dir = resourceFolder("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}
