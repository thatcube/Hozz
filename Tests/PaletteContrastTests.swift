import SwiftUI
import Testing
import UIKit

@testable import HozzUI

/// Pins the palette's legibility.
///
/// Every one of these was measured rather than judged by eye, and the point of
/// writing them down is that the next person to pick a nicer-looking navy finds
/// out here rather than after shipping. Colour is the one part of an interface
/// where a change can be an improvement and a regression at the same time, and
/// only one of those is visible while you are making it.
///
/// The thresholds are WCAG 2.1: 4.5:1 for body text, 3:1 for a graphical
/// element or large text.
struct PaletteContrastTests {
    // MARK: - Reading a colour as it will actually be drawn

    private static func components(
        _ color: Color,
        _ style: UIUserInterfaceStyle
    ) -> (red: Double, green: Double, blue: Double) {
        let resolved = UIColor(color).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: style)
        )
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue))
    }

    private static func luminance(
        _ color: Color,
        _ style: UIUserInterfaceStyle
    ) -> Double {
        let parts = components(color, style)
        func channel(_ value: Double) -> Double {
            value <= 0.03928
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(parts.red)
            + 0.7152 * channel(parts.green)
            + 0.0722 * channel(parts.blue)
    }

    private static func ratio(
        _ first: Color,
        on second: Color,
        _ style: UIUserInterfaceStyle
    ) -> Double {
        let a = luminance(first, style)
        let b = luminance(second, style)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static let styles: [(String, UIUserInterfaceStyle)] = [
        ("light", .light),
        ("dark", .dark)
    ]

    // MARK: - Text

    @Test
    func textIsLegibleOnEverySurfaceItIsDrawnOn() {
        let surfaces: [(String, Color)] = [
            ("air", HozzPalette.air),
            ("cardTop", HozzPalette.cardTop),
            ("cardBottom", HozzPalette.cardBottom),
            ("blueWash", HozzPalette.blueWash),
            ("warningWell", HozzPalette.warningWell),
            ("positiveWell", HozzPalette.positiveWell),
            ("neutralWell", HozzPalette.neutralWell),
            ("warningWash", HozzPalette.warningWash)
        ]
        let inks: [(String, Color)] = [
            ("ink", HozzPalette.ink),
            ("inkSoft", HozzPalette.inkSoft),
            ("inkMuted", HozzPalette.inkMuted)
        ]

        for (styleName, style) in Self.styles {
            for (surfaceName, surface) in surfaces {
                for (inkName, ink) in inks {
                    let measured = Self.ratio(ink, on: surface, style)
                    #expect(
                        measured >= 4.5,
                        """
                        \(inkName) on \(surfaceName) in \(styleName) is \
                        \(measured), under the 4.5 body text needs.
                        """
                    )
                }
            }
        }
    }

    /// Warning and positive carry sentences, not just icons, so they are held
    /// to the text threshold rather than the graphical one — including on the
    /// tinted surfaces they are drawn on.
    @Test
    func statusTonesAreLegibleAsText() {
        let surfaces: [(String, Color)] = [
            ("air", HozzPalette.air),
            ("cardTop", HozzPalette.cardTop),
            ("cardBottom", HozzPalette.cardBottom)
        ]

        for (styleName, style) in Self.styles {
            for (surfaceName, surface) in surfaces {
                for (toneName, tone) in [
                    ("actionText", HozzPalette.actionText),
        ("warning", HozzPalette.warning),
                    ("positive", HozzPalette.positive)
                ] {
                    let measured = Self.ratio(tone, on: surface, style)
                    #expect(
                        measured >= 4.5,
                        "\(toneName) on \(surfaceName) in \(styleName) is \(measured)"
                    )
                }
            }
        }
    }

    // MARK: - Graphics

    @Test
    func theBrandBlueReadsAsAShapeWhereverItIsDrawn() {
        let surfaces: [(String, Color)] = [
            ("air", HozzPalette.air),
            ("cardTop", HozzPalette.cardTop),
            ("cardBottom", HozzPalette.cardBottom),
            ("iconWell", HozzPalette.iconWell)
        ]

        for (styleName, style) in Self.styles {
            for (surfaceName, surface) in surfaces {
                let measured = Self.ratio(HozzPalette.blue, on: surface, style)
                #expect(
                    measured >= 3,
                    """
                    blue on \(surfaceName) in \(styleName) is \(measured), \
                    under the 3 a graphical element needs.
                    """
                )
            }
        }
    }

    /// A button label is not large text, so 3:1 is not enough for it.
    @Test
    func aFilledButtonsLabelMeetsBodyContrast() {
        for (styleName, style) in Self.styles {
            let measured = Self.ratio(
                HozzPalette.onAction,
                on: HozzPalette.actionFill,
                style
            )
            #expect(
                measured >= 4.5,
                "the filled button in \(styleName) is \(measured)"
            )
        }
    }

    /// The brand blue is legible as a shape but not as a word, which is why
    /// ``HozzPalette/actionText`` exists.
    ///
    /// Without this the rule was only written down. The quiet button's label
    /// and the "Easiest" chip both put blue text on a blue tint, at 3.10 and
    /// 2.97 — the second being the exact pairing the palette's own comment
    /// calls out as failing even the graphical threshold.
    @Test
    func blueTextIsLegibleOnEveryTintItIsDrawnOn() {
        let surfaces: [(String, Color)] = [
            ("cardTop", HozzPalette.cardTop),
            ("cardBottom", HozzPalette.cardBottom),
            ("blueWash", HozzPalette.blueWash),
            ("iconWell", HozzPalette.iconWell)
        ]

        for (styleName, style) in Self.styles {
            for (surfaceName, surface) in surfaces {
                let measured = Self.ratio(
                    HozzPalette.actionText,
                    on: surface,
                    style
                )
                #expect(
                    measured >= 4.5,
                    """
                    actionText on \(surfaceName) in \(styleName) is \
                    \(measured), under the 4.5 a word needs.
                    """
                )
            }
        }
    }

    /// Every quiet button reads: each tone's label against its own fill.
    @Test
    func everyQuietButtonToneIsLegibleOnItsOwnFill() {
        let tones: [(String, HozzTone)] = [
            ("action", .action),
            ("neutral", .neutral),
            ("positive", .positive),
            ("warning", .warning)
        ]

        for (styleName, style) in Self.styles {
            for (name, tone) in tones {
                let measured = Self.ratio(tone.textColor, on: tone.well, style)
                #expect(
                    measured >= 4.5,
                    "the \(name) quiet button in \(styleName) is \(measured)"
                )
            }
        }
    }

    /// And every icon in its disc reads as a shape.
    @Test
    func everyIconToneIsVisibleInItsOwnWell() {
        let tones: [(String, HozzTone)] = [
            ("action", .action),
            ("neutral", .neutral),
            ("positive", .positive),
            ("warning", .warning)
        ]

        for (styleName, style) in Self.styles {
            for (name, tone) in tones {
                let measured = Self.ratio(tone.color, on: tone.well, style)
                #expect(
                    measured >= 3,
                    "the \(name) icon in \(styleName) is \(measured)"
                )
            }
        }
    }

    // MARK: - Staying derivable

    /// Every token the palette publishes, so a check here cannot be sidestepped
    /// by adding a colour and not listing it.
    private static let everyToken: [(String, Color)] = [
        ("blue", HozzPalette.blue),
        ("blueWash", HozzPalette.blueWash),
        ("mist", HozzPalette.mist),
        ("air", HozzPalette.air),
        ("ink", HozzPalette.ink),
        ("inkSoft", HozzPalette.inkSoft),
        ("inkMuted", HozzPalette.inkMuted),
        ("line", HozzPalette.line),
        ("lineSoft", HozzPalette.lineSoft),
        ("bloom", HozzPalette.bloom),
        ("cardTop", HozzPalette.cardTop),
        ("cardBottom", HozzPalette.cardBottom),
        ("iconWell", HozzPalette.iconWell),
        ("actionFill", HozzPalette.actionFill),
        ("onAction", HozzPalette.onAction),
        ("actionText", HozzPalette.actionText),
        ("warning", HozzPalette.warning),
        ("positive", HozzPalette.positive),
        ("warningWell", HozzPalette.warningWell),
        ("positiveWell", HozzPalette.positiveWell),
        ("neutralWell", HozzPalette.neutralWell),
        ("warningWash", HozzPalette.warningWash),
        ("skeleton", HozzPalette.skeleton),
        ("cardShadow", HozzPalette.cardShadow)
    ]

    /// The palette has to stay something a script can read.
    ///
    /// The website already carries these colours, and it agrees with this file
    /// only because they were copied across by hand — two copies of one fact,
    /// with nothing checking them. A generator can derive the CSS from a list
    /// of flat opaque values; it cannot derive it from one token defined as
    /// another at 14%, or from a system material. So this asserts the property
    /// that keeps that door open, rather than trusting a comment asking people
    /// not to close it.
    @Test
    func everyTokenIsAFlatOpaqueColour() {
        for (styleName, style) in Self.styles {
            for (name, color) in Self.everyToken {
                let resolved = UIColor(color).resolvedColor(
                    with: UITraitCollection(userInterfaceStyle: style)
                )
                var alpha: CGFloat = 0
                let read = resolved.getRed(nil, green: nil, blue: nil, alpha: &alpha)
                #expect(
                    read,
                    "\(name) in \(styleName) is not a plain RGB colour"
                )
                #expect(
                    alpha == 1,
                    """
                    \(name) in \(styleName) has alpha \(alpha). Tokens are \
                    written as flat hex so the palette stays derivable; write \
                    the composited result out instead of an opacity variant.
                    """
                )
            }
        }
    }

    /// Light and dark are given separately for every token, so neither
    /// appearance can quietly fall back to the other's value.
    ///
    /// `onAction` is the one exception worth allowing in principle, and it is
    /// not one in practice — white on a deep blue, near-black on a pale one.
    @Test
    func everyTokenIsDesignedForBothAppearances() {
        for (name, color) in Self.everyToken where name != "cardShadow" {
            let light = Self.components(color, .light)
            let dark = Self.components(color, .dark)
            #expect(
                light != dark,
                """
                \(name) is the same value in both appearances. Dark is \
                designed here rather than inherited, so this is either a \
                missing dark value or a token that should say why.
                """
            )
        }
    }

    // MARK: - Shape

    /// A card must be visible as a card.
    ///
    /// This is the check that would have caught the obvious way to make dark
    /// mode darker: darkening the page and leaving the card alone, which
    /// darkens the card with it and leaves a page with no cards on it.
    @Test
    func aCardIsDistinguishableFromThePageBehindIt() {
        for (styleName, style) in Self.styles {
            let card = Self.luminance(HozzPalette.cardTop, style)
            let page = Self.luminance(HozzPalette.air, style)
            let hairline = Self.ratio(
                HozzPalette.lineSoft,
                on: HozzPalette.cardTop,
                style
            )
            let separated = abs(card - page) > 0.002 || hairline >= 1.08
            #expect(
                separated,
                """
                In \(styleName) a card is indistinguishable from the page: \
                card luminance \(card), page \(page), hairline \(hairline).
                """
            )
        }
    }

    /// Dark mode is meant to be dark. Brandon asked for this specifically, and
    /// "darker" is a claim that can be checked rather than asserted.
    @Test
    func darkModeIsActuallyDark() {
        let page = Self.luminance(HozzPalette.air, .dark)
        #expect(
            page < 0.01,
            "the dark page has luminance \(page), which is not dark"
        )

        let card = Self.luminance(HozzPalette.cardTop, .dark)
        #expect(
            card < 0.02,
            "a dark card has luminance \(card), which is not dark"
        )

        // Lifted rather than sunk: on a near-black page a card that is darker
        // still cannot be seen at all.
        #expect(card > page, "a dark card should sit above the page, not below")
    }
}
