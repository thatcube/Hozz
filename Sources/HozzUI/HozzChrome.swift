import SwiftUI

/// The website's surface language, in the smallest set of pieces that can
/// rebuild it: a pale page with light falling across it, cards that lift by
/// almost nothing, and type that is either a large tight number or a small
/// wide-tracked label.
///
/// It lives here rather than in the app because the site's look is the app's
/// look on both platforms, and because a card drawn slightly differently on
/// each screen is how a design language quietly stops being one.
///
/// Everything is drawn from ``HozzPalette``. Nothing here invents a colour.

// MARK: - The page

/// The wash behind a whole screen: an almost-white page with two soft blooms
/// of light, one high and right, one low and left.
///
/// The blooms are radial and fade to nothing well before the edge, which is
/// what makes them read as light rather than as a coloured panel. Their radius
/// is taken from the view's own size so a phone and an iPad get the same
/// proportion of glow rather than the same number of points — at a fixed
/// radius the iPad's blooms shrink to smudges in the corners.
public struct HozzSurface: View {
    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let span = max(proxy.size.width, proxy.size.height)
            HozzPalette.air
                .overlay(alignment: .topTrailing) {
                    bloom(radius: span * 0.62, opacity: 0.5)
                        .offset(x: span * 0.16, y: -span * 0.18)
                }
                .overlay(alignment: .bottomLeading) {
                    bloom(radius: span * 0.5, opacity: 0.3)
                        .offset(x: -span * 0.2, y: span * 0.16)
                }
        }
        .ignoresSafeArea()
    }

    private func bloom(radius: CGFloat, opacity: Double) -> some View {
        RadialGradient(
            colors: [HozzPalette.bloom.opacity(opacity), .clear],
            center: .center,
            startRadius: 0,
            endRadius: radius
        )
        .frame(width: radius * 2, height: radius * 2)
    }
}

// MARK: - Cards

/// A card the way the site draws one: a shallow diagonal wash, a hairline that
/// barely separates it from the page, and a wide faint shadow.
///
/// The shadow is deliberately almost invisible — the site lifts a card with a
/// large blur at around four per cent, and anything heavier turns a page of
/// cards into a page of tiles.
public struct HozzCard: ViewModifier {
    private let padding: CGFloat
    private let radius: CGFloat

    public init(padding: CGFloat = 18, radius: CGFloat = 20) {
        self.padding = padding
        self.radius = radius
    }

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HozzPalette.cardWash, in: shape)
            .overlay(shape.strokeBorder(HozzPalette.lineSoft, lineWidth: 1))
            .shadow(color: HozzPalette.cardShadow.opacity(0.05), radius: 18, y: 10)
            .shadow(color: HozzPalette.cardShadow.opacity(0.03), radius: 2, y: 1)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

extension View {
    /// Draws this content as a card in the site's style.
    public func hozzCard(padding: CGFloat = 18, radius: CGFloat = 20) -> some View {
        modifier(HozzCard(padding: padding, radius: radius))
    }

    /// Puts the page wash behind this content.
    public func hozzSurface() -> some View {
        background(HozzSurface())
    }
}

// MARK: - Type

extension Text {
    /// A headline number. Large, tightly tracked, and only semibold — the site
    /// never reaches for a heavy weight, it reaches for size.
    public func hozzDisplay(size: CGFloat = 34) -> Text {
        font(.system(size: size, weight: .semibold, design: .rounded))
            .tracking(size * -0.02)
            .foregroundColor(HozzPalette.ink)
    }

    /// The small wide-tracked label above a value or a section. Uppercasing is
    /// left to the caller so a proper noun can keep its own case.
    public func hozzLabel() -> Text {
        font(.system(size: 11, weight: .medium))
            .tracking(1.1)
            .foregroundColor(HozzPalette.inkMuted)
    }

    /// The unit or qualifier that trails a headline number.
    public func hozzUnit() -> Text {
        font(.system(size: 14, weight: .medium))
            .foregroundColor(HozzPalette.inkSoft)
    }

    /// A sentence explaining something, under a value or a chart.
    public func hozzCaption() -> Text {
        font(.system(size: 12))
            .foregroundColor(HozzPalette.inkMuted)
    }
}
