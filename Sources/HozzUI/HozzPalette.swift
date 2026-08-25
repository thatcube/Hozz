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
///
/// Dark is designed rather than inverted, and it is deliberately much darker
/// than the site: a page of near-black navy, with cards *lifted* off it. That
/// is the opposite of light, where the page is the palest tone and a card is
/// faintly tinted *down* from it — so the card cannot simply reuse the page
/// tones in both, and has ``cardTop``/``cardBottom`` of its own.
///
/// Every pairing here has been measured rather than judged by eye, and
/// `PaletteContrastTests` pins the ratios so a nicer-looking tone cannot
/// quietly drop text below legibility.
///
/// ## Why every value here is a flat hex literal
///
/// The website already carries this palette, and it agrees with this file only
/// because the values were copied across by hand. Nothing enforces it. Keeping
/// every token as a literal `Color(light:dark:)` pair — never a blend, never an
/// opacity variant of another token, never a system material — is what leaves a
/// generator or a drift check able to read this one file and derive the CSS.
///
/// So where a tone is *conceptually* another one at low alpha — the tinted disc
/// behind a warning icon, say — the composited result is written out as its own
/// hex and the derivation recorded in the comment, rather than computed at
/// runtime. It costs a line of arithmetic once and keeps the palette
/// enumerable.
///
/// Two things here are deliberately **not** flat, and both are real constraints
/// on that ambition rather than oversights:
///
/// - ``cardWash`` and ``surfaceWash`` are gradients. They are still derivable,
///   because each is stated as two named stops and a direction, which is what
///   a CSS `linear-gradient` needs.
/// - The alphas in `HozzSurface`'s blooms and `HozzCard`'s shadows are part of
///   a gradient stop and a shadow spec, not colours in their own right. CSS
///   expresses both the same way, as `rgba()` inside the effect.
///
/// Chart rendering in `App/Dashboard/MetricChart.swift` also varies the brand
/// blue's alpha per mark. That is a drawing parameter for a plot, not a surface
/// token, and it is the one part of the app a web port would have to reimplement
/// rather than map.
public enum HozzPalette {
    /// The brand blue. Mid-tone on purpose: it has to carry a tinted control on
    /// white and a filled one on navy without changing character.
    public static let blue = Color(light: 0x5D8CB0, dark: 0x7CB4DE)

    /// A wash for a selected row or a filled chip. Light enough to put text on.
    public static let blueWash = Color(light: 0xDCECF6, dark: 0x16293A)

    /// The palest blue. A whole-surface tint, not a fill.
    public static let mist = Color(light: 0xEDF6FC, dark: 0x0B1620)

    /// Almost white, faintly cool. The page under everything.
    public static let air = Color(light: 0xF8FBFD, dark: 0x05090F)

    /// Body text. Deep navy rather than black, which is what keeps the site
    /// soft — and the darkest tone in the mark.
    public static let ink = Color(light: 0x132638, dark: 0xE9F2F9)

    /// Secondary text: a caption, or a value's unit.
    public static let inkSoft = Color(light: 0x3F5568, dark: 0xA7C3D8)

    /// Tertiary text. Still readable; not competing.
    public static let inkMuted = Color(light: 0x4E6274, dark: 0x8AA8BF)

    /// A rule between rows.
    public static let line = Color(light: 0xCBDCE7, dark: 0x24384A)

    /// A rule that should barely register.
    public static let lineSoft = Color(light: 0xDEEBF2, dark: 0x1A2A38)

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
    public static let bloom = Color(light: 0xCAE1F1, dark: 0x16344E)

    /// The top of a card's wash.
    ///
    /// In light this is ``air`` — the card is the page tone, tinted very
    /// slightly down towards ``mist`` and held apart from the page by a
    /// hairline. In dark it is the reverse: the page is near-black and the
    /// card is *lifted* off it, because a card the same value as a dark page
    /// is not a card, it is a rectangle nobody can see.
    public static let cardTop = Color(light: 0xF8FBFD, dark: 0x111C28)

    /// The bottom of a card's wash. See ``cardTop``.
    public static let cardBottom = Color(light: 0xEDF6FC, dark: 0x0C1621)

    /// The tinted disc an icon sits in.
    ///
    /// Paler than ``blueWash`` in light for one measured reason: the brand
    /// blue on ``blueWash`` is 2.97:1, just under the 3:1 a graphical element
    /// needs, and this brings it to 3.10:1 without changing the character.
    public static let iconWell = Color(light: 0xE4F0F9, dark: 0x16293A)

    /// The fill behind a filled button, with ``onAction`` on top of it.
    ///
    /// Deeper than ``blue`` in light, and only here: white on the brand blue
    /// is 3.59:1, which is under AA for anything but large text, and a button
    /// label is not large text. This is 4.58:1. In dark the pale blue carries
    /// near-black at 8.97:1, so it is ``blue`` itself.
    public static let actionFill = Color(light: 0x4C7A9E, dark: 0x7CB4DE)

    /// What is written on ``actionFill``.
    public static let onAction = Color(light: 0xFFFFFF, dark: 0x05090F)

    /// The brand blue *as a word*: a link, a prominent row's title, the label
    /// on a quiet button, the text in a chip.
    ///
    /// Deeper than ``blue`` in light, and for a measured reason. The brand blue
    /// is 3.46:1 on a card and 2.97:1 on ``blueWash`` — fine for an icon, under
    /// AA for anything anyone has to read. This clears 4.5:1 on every surface
    /// it is drawn on, the worst being ``blueWash`` at 4.62:1. In dark the pale
    /// blue already carries text comfortably, so it is ``blue`` itself.
    ///
    /// Icons keep ``blue``. A shape only needs 3:1, and holding the mark's own
    /// hue where it is seen rather than read is what keeps the app looking like
    /// the site.
    public static let actionText = Color(light: 0x436C8C, dark: 0x7CB4DE)

    /// Something the person can act on: an export that could not finish, a
    /// destination that stopped working.
    ///
    /// A single definition because it was `.orange` in seventeen places across
    /// eight files, and `.orange` is a system tone that belongs to no palette —
    /// it read as a notification from a different app every time it appeared.
    public static let warning = Color(light: 0x9E5320, dark: 0xF0B27A)

    /// Something that worked. Was `.green` in five places, for the same reason
    /// and with the same result.
    public static let positive = Color(light: 0x2A7252, dark: 0x7FCBA4)

    /// The disc behind a warning icon: ``warning`` at 14% over ``cardTop``,
    /// composited once here rather than at runtime, then hand-adjusted back
    /// towards the hue — a warm tone blended into navy at low alpha goes grey.
    public static let warningWell = Color(light: 0xF6E7DA, dark: 0x33261B)

    /// The disc behind a positive icon. Derived as ``warningWell`` is.
    public static let positiveWell = Color(light: 0xDCEDE4, dark: 0x18302A)

    /// The disc behind an icon that is neither: ``inkSoft`` at 12% over
    /// ``cardTop``.
    public static let neutralWell = Color(light: 0xE4EAEF, dark: 0x1D2A36)

    /// A whole panel tinted because what it holds needs attention — an
    /// incomplete recording, say. Paler than ``warningWell``, because a panel
    /// covers far more area than a disc.
    public static let warningWash = Color(light: 0xF8EFE7, dark: 0x241C14)

    /// The block standing in for a value that is still being read.
    ///
    /// A skeleton rather than a spinner per card, which would make a grid of
    /// cards flicker. ``lineSoft`` at 60% over ``cardTop``.
    public static let skeleton = Color(light: 0xE9F1F7, dark: 0x17242F)

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
            colors: [cardTop, cardBottom],
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

    /// Tones for telling several series apart on one chart.
    ///
    /// Added because comparing types is the thing a desktop screen is for, and
    /// one blue cannot carry four lines. They are deliberately close in weight
    /// and saturation to the brand blue rather than a bright categorical set:
    /// the page stays quiet, and no single series shouts louder than the others
    /// for a reason that has nothing to do with the data.
    ///
    /// The first is `blue` itself, so a chart with one series is unchanged.
    public static let series: [Color] = [
        blue,
        Color(light: 0x4E9A93, dark: 0x86C9C1),
        Color(light: 0x8A7FB2, dark: 0xB9AEDC),
        Color(light: 0xC08B62, dark: 0xE0B48C)
    ]

    /// A stable colour for the nth series on a chart.
    public static func series(_ index: Int) -> Color {
        series[abs(index) % series.count]
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
