import SwiftUI

/// The colours the website already uses, so the app and the site look like one
/// thing rather than two.
///
/// These are lifted from the site's shipping stylesheet rather than sampled by
/// eye, and they are the same tones the app icon is drawn from: a pale droplet
/// over deep navy. The names are the site's own, so a change there can be
/// followed here without translating twice.
///
/// Light and dark are given separately. The site is a light page and its ink is
/// nearly black, which is unreadable inverted, so dark mode lifts the ink to the
/// palest tone rather than reusing the same value in both.
public enum HozzPalette {
    /// The brand blue. Mid-tone on purpose: it has to carry a tinted control on
    /// white and a filled one on navy without changing character.
    public static let blue = Color(light: 0x5D8CB0, dark: 0x96C2E0)

    /// A wash for a selected row or a filled chip. Light enough to put text on.
    public static let blueWash = Color(light: 0xDCECF6, dark: 0x1B3348)

    /// The palest blue. A whole-surface tint, not a fill.
    public static let mist = Color(light: 0xEDF6FC, dark: 0x16293C)

    /// Almost white, faintly cool. The page under everything.
    public static let air = Color(light: 0xF8FBFD, dark: 0x101E2C)

    /// Body text. Deep navy rather than black, which is what keeps the site
    /// soft — and the darkest tone in the mark.
    public static let ink = Color(light: 0x132638, dark: 0xEDF6FC)

    /// Secondary text: a caption, or a value's unit.
    public static let inkSoft = Color(light: 0x3F5568, dark: 0xB9D7EB)

    /// Tertiary text. Still readable; not competing.
    public static let inkMuted = Color(light: 0x4E6274, dark: 0x96BCD6)

    /// A rule between rows.
    public static let line = Color(light: 0xCBDCE7, dark: 0x24405A)

    /// A rule that should barely register.
    public static let lineSoft = Color(light: 0xDEEBF2, dark: 0x1C3446)

    /// The site's `--blue-light`, which is the colour every soft glow on the
    /// page is made of — always as a radial fading to nothing, never as a fill.
    ///
    /// It sits between ``blueWash`` and ``blue``, and neither substitutes for
    /// it: the wash is too pale to register once faded, and the brand blue is
    /// strong enough to read as a coloured shape rather than as light.
    ///
    /// Dark is a lifted navy rather than the same pale value, for the reason
    /// the ink is inverted — a pale bloom on a dark page is a smear, whereas a
    /// navy one lightened slightly reads as the same light falling on a darker
    /// surface.
    public static let bloom = Color(light: 0xCAE1F1, dark: 0x2A4E71)

    /// The app's tint: the colour of a button, a selected row, a chart line.
    ///
    /// This is ``blue`` under a name that says what it is for. It exists as its
    /// own token because the app previously tinted itself with a teal that
    /// appears nowhere on the website, and naming the role separately from the
    /// hue is what lets the two stay in step from here on.
    public static let action = blue

    /// The shadow under a card.
    ///
    /// Nearly transparent on purpose. The site's cards are lifted by a wide,
    /// very faint navy blur rather than a grey drop shadow, and anything
    /// stronger turns the airy surface into a stack of tiles.
    public static let cardShadow = Color(light: 0x132638, dark: 0x000000)

    /// The soft diagonal wash behind a card on the website.
    ///
    /// Kept shallow deliberately: it reads as light falling across a surface,
    /// and a steeper ramp reads as a coloured box instead.
    public static var cardWash: LinearGradient {
        LinearGradient(
            colors: [air, mist],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The wash behind a whole screen.
    public static var surfaceWash: LinearGradient {
        LinearGradient(
            colors: [air, blueWash.opacity(0.45)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension Color {
    /// A colour that differs between light and dark, written as the hex the
    /// website uses so the two can be compared at a glance.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
        #else
        self.init(hex: light)
        #endif
    }

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif
