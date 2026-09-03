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

    public init(
        padding: CGFloat = HozzMetrics.cardPadding,
        radius: CGFloat = HozzMetrics.cardRadius
    ) {
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
    public func hozzCard(
        padding: CGFloat = HozzMetrics.cardPadding,
        radius: CGFloat = HozzMetrics.cardRadius
    ) -> some View {
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

// MARK: - The numbers, once

/// Every measurement the app's chrome is built from.
///
/// These were written out by hand on each screen, which is how the dashboard
/// came to sit on an 18-point gutter while everything else sat on whatever
/// `List` happened to use. A layout value that appears in two files is a
/// layout value that will disagree with itself.
public enum HozzMetrics {
    /// The margin down each side of a screen.
    public static let gutter: CGFloat = 18

    /// Between two cards in the same group.
    public static let cardGap: CGFloat = 10

    /// Between two cards in a grid, which need slightly more air than a
    /// stack because they are wider than they are tall.
    public static let gridGap: CGFloat = 13

    /// Above the first thing on a screen.
    public static let screenTop: CGFloat = 8

    /// Below the last thing on a screen, clearing the tab bar.
    public static let screenBottom: CGFloat = 28

    /// Between one titled group and the next.
    public static let sectionGap: CGFloat = 22

    /// Inside a card holding a block of content.
    public static let cardPadding: CGFloat = 18

    /// Inside a card holding a single row.
    public static let rowPadding: CGFloat = 14

    /// The corner of a content card.
    public static let cardRadius: CGFloat = 20

    /// The corner of a row card. Slightly tighter, because a short card with
    /// the same radius reads as a lozenge.
    public static let rowRadius: CGFloat = 16

    /// The corner of a button.
    public static let buttonRadius: CGFloat = 14

    /// A control the person cannot use right now.
    public static let disabledOpacity: Double = 0.4

    /// A control under a finger or a pointer.
    public static let pressedOpacity: Double = 0.82

    /// The wider margin a desktop canvas can carry without reading as a
    /// stretched phone screen.
    public static let desktopPageInset: CGFloat = 26

    /// Between dashboard panels on a desktop canvas.
    public static let desktopGutter: CGFloat = 18

    /// Desktop panels are wider and shallower than phone cards.
    public static let desktopCardRadius: CGFloat = 14

    /// The stable width of a desktop master list beside its detail.
    public static let desktopListWidth: CGFloat = 290
}

// MARK: - Meaning, as colour

/// What a piece of chrome is saying, rather than what colour it is.
///
/// Written as a tone so a row that reports a failure cannot be orange on one
/// screen and red on the next, and so "attention" can be restated once instead
/// of in every view that needs it.
public enum HozzTone: Sendable {
    /// Ordinary content.
    case neutral
    /// Something to act on.
    case action
    /// Something that worked.
    case positive
    /// Something the person can do something about.
    case warning

    /// What this tone draws with.
    public var color: Color {
        switch self {
        case .neutral: HozzPalette.inkSoft
        case .action: HozzPalette.blue
        case .positive: HozzPalette.positive
        case .warning: HozzPalette.warning
        }
    }

    /// What this tone writes with.
    ///
    /// Only ``action`` differs from ``color``: the brand blue is legible as a
    /// shape but not as a word. See ``HozzPalette/actionText``.
    public var textColor: Color {
        switch self {
        case .action: HozzPalette.actionText
        case .neutral, .positive, .warning: color
        }
    }

    /// The tinted surface this tone sits on: a disc behind an icon, or the
    /// fill of a quiet button.
    ///
    /// A named token per tone rather than ``color`` at some alpha, so the
    /// palette stays a list of flat values a generator can read.
    public var well: Color {
        switch self {
        case .neutral: HozzPalette.neutralWell
        case .action: HozzPalette.iconWell
        case .positive: HozzPalette.positiveWell
        case .warning: HozzPalette.warningWell
        }
    }
}

// MARK: - A screen

/// A whole screen: the page wash, the gutter, and a stack of groups.
///
/// Everything outside the dashboard used to be a `List`, which brought its own
/// grey page, its own margins and its own idea of what a row looks like. This
/// is the same container the dashboard already used, named so the rest of the
/// app can use it too rather than approximating it.
public struct HozzScreen<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(
        spacing: CGFloat = HozzMetrics.sectionGap,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(.horizontal, HozzMetrics.gutter)
            .padding(.top, HozzMetrics.screenTop)
            .padding(.bottom, HozzMetrics.screenBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HozzSurface())
    }
}

/// The title over a screen: the day, then what this is.
public struct HozzScreenTitle: View {
    private let eyebrow: String?
    private let title: String

    public init(_ title: String, eyebrow: String? = nil) {
        self.title = title
        self.eyebrow = eyebrow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let eyebrow {
                Text(eyebrow).hozzLabel().textCase(.uppercase)
            }
            Text(title)
                .hozzDisplay(size: 30)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A desktop page keeps the shared surface and rhythm while leaving room for
/// native sidebars, tables, charts, and pointer-sized controls.
public struct HozzDesktopPage<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HozzMetrics.desktopGutter) {
                content
            }
            .padding(HozzMetrics.desktopPageInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HozzSurface())
    }
}

/// A desktop page heading. The type language matches iPhone, while its
/// horizontal composition remains native to a wide window.
public struct HozzPageHeader<Accessory: View>: View {
    private let title: Text
    private let subtitle: Text?
    private let accessory: Accessory
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 28

    public init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.accessory = accessory()
    }

    public init(
        verbatim title: String,
        subtitle: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = Text(verbatim: title)
        self.subtitle = subtitle.map { Text(verbatim: $0) }
        self.accessory = accessory()
    }

    public init(
        _ title: LocalizedStringKey,
        verbatimSubtitle subtitle: String?,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text(verbatim: $0) }
        self.accessory = accessory()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .lastTextBaseline, spacing: 18) {
                heading
                Spacer(minLength: 16)
                accessory
            }
            VStack(alignment: .leading, spacing: 12) {
                heading
                HStack {
                    Spacer(minLength: 0)
                    accessory
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            title
                .hozzDisplay(size: titleSize)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                subtitle
                    .font(.callout)
                    .foregroundStyle(HozzPalette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension HozzPageHeader where Accessory == EmptyView {
    public init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }

    public init(verbatim title: String, subtitle: String? = nil) {
        self.init(verbatim: title, subtitle: subtitle) { EmptyView() }
    }

    public init(_ title: LocalizedStringKey, verbatimSubtitle subtitle: String?) {
        self.init(title, verbatimSubtitle: subtitle) { EmptyView() }
    }
}

/// A titled desktop panel built from the same card surface as iPhone.
public struct HozzPanel<Content: View>: View {
    private let title: Text?
    private let subtitle: Text?
    private let accessory: AnyView?
    private let content: Content

    public init(
        title: LocalizedStringKey? = nil,
        subtitle: LocalizedStringKey? = nil,
        accessory: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title.map { Text($0) }
        self.subtitle = subtitle.map { Text($0) }
        self.accessory = accessory
        self.content = content()
    }

    public init(
        verbatimTitle title: String,
        verbatimSubtitle subtitle: String? = nil,
        accessory: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = Text(verbatim: title)
        self.subtitle = subtitle.map { Text(verbatim: $0) }
        self.accessory = accessory
        self.content = content()
    }

    public init(
        title: LocalizedStringKey,
        verbatimSubtitle subtitle: String?,
        accessory: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text(verbatim: $0) }
        self.accessory = accessory
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || subtitle != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            title
                                .font(.headline)
                                .foregroundStyle(HozzPalette.ink)
                        }
                        if let subtitle {
                            subtitle
                                .font(.caption)
                                .foregroundStyle(HozzPalette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .hozzCard(
            padding: HozzMetrics.cardPadding,
            radius: HozzMetrics.desktopCardRadius
        )
    }
}

/// One dashboard number with its meaning immediately beside it.
public struct HozzStatTile: View {
    private let label: String
    private let value: String
    private let unit: String?
    private let caption: String?
    private let tone: Color

    public init(
        label: String,
        value: String,
        unit: String? = nil,
        caption: String? = nil,
        tone: Color = HozzPalette.ink
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.caption = caption
        self.tone = tone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(HozzPalette.inkMuted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(tone)
                    .monospacedDigit()
                if let unit, !unit.isEmpty {
                    Text(unit)
                        .font(.callout)
                        .foregroundStyle(HozzPalette.inkSoft)
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(HozzPalette.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - A group of cards

/// A titled group: a small wide-tracked label, some cards, and an optional
/// sentence underneath.
///
/// Deliberately not a `List` section. The dashboard's groups are separate
/// cards with air between them rather than rows sharing one white slab, and
/// that difference is most of what made the two halves of the app look like
/// two apps.
public struct HozzSection<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let spacing: CGFloat
    private let content: Content

    public init(
        _ title: String? = nil,
        footer: String? = nil,
        spacing: CGFloat = HozzMetrics.cardGap,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title)
                    .hozzLabel()
                    .textCase(.uppercase)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }

            VStack(spacing: spacing) {
                content
            }

            if let footer {
                Text(footer)
                    .hozzCaption()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rows

/// The chevron that says a row leads somewhere.
public struct HozzChevron: View {
    public init() {}

    public var body: some View {
        HozzIconView(.chevronRight, size: 14)
            .foregroundStyle(HozzPalette.inkMuted)
    }
}

/// An icon in its own tinted disc, the way the dashboard draws one.
public struct HozzIconWell: View {
    private let icon: HozzIcon
    private let tone: HozzTone
    private let diameter: CGFloat

    public init(_ icon: HozzIcon, tone: HozzTone = .action, diameter: CGFloat = 30) {
        self.icon = icon
        self.tone = tone
        self.diameter = diameter
    }

    public var body: some View {
        HozzIconView(icon, size: diameter * 0.57)
            .foregroundStyle(tone.color)
            .frame(width: diameter, height: diameter)
            .background(tone.well, in: Circle())
    }
}

/// One row, drawn as its own card.
///
/// Takes a title and an optional second line, because that is the shape almost
/// every row in the app already had — a name and a sentence saying what state
/// it is in — written out longhand each time.
public struct HozzRow<Trailing: View>: View {
    private let icon: HozzIcon?
    private let tone: HozzTone
    private let title: String
    private let detail: String?
    private let isProminent: Bool
    private let trailing: Trailing

    public init(
        _ title: String,
        detail: String? = nil,
        icon: HozzIcon? = nil,
        tone: HozzTone = .action,
        isProminent: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.tone = tone
        self.isProminent = isProminent
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let icon {
                HozzIconWell(icon, tone: tone)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isProminent ? tone.textColor : HozzPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if let detail {
                    Text(detail)
                        .hozzCaption()
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: 0)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hozzCard(padding: HozzMetrics.rowPadding, radius: HozzMetrics.rowRadius)
    }
}

extension HozzRow where Trailing == EmptyView {
    public init(
        _ title: String,
        detail: String? = nil,
        icon: HozzIcon? = nil,
        tone: HozzTone = .action,
        isProminent: Bool = false
    ) {
        self.init(
            title,
            detail: detail,
            icon: icon,
            tone: tone,
            isProminent: isProminent
        ) { EmptyView() }
    }
}

/// A statement inside a card: an icon and a sentence, in a tone.
///
/// This is the shape of every "how background sync behaves" line, every
/// caveat, and every warning in the app, each of which was previously a
/// hand-built `Label` with its own font and its own system colour.
public struct HozzNote: View {
    private let icon: HozzIcon
    private let text: String
    private let tone: HozzTone

    public init(_ text: String, icon: HozzIcon, tone: HozzTone = .neutral) {
        self.text = text
        self.icon = icon
        self.tone = tone
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 11) {
            HozzIconView(icon, size: 17)
                .foregroundStyle(tone.color)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 13))
                // Only a warning colours its own sentence. A page where every
                // line is tinted has no emphasis left to spend: eleven green
                // sentences under "Coverage" read as eleven alerts rather than
                // as a list of things that work.
                .foregroundStyle(
                    tone == .warning ? HozzPalette.warning : HozzPalette.inkSoft
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Several notes in one card, which is how a list of statements reads best:
/// one surface, not one card per sentence.
public struct HozzNoteCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            content
        }
        .hozzCard()
    }
}

// MARK: - Buttons

/// The one filled button in the app.
public struct HozzFilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(HozzPalette.onAction)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                HozzPalette.actionFill,
                in: RoundedRectangle(
                    cornerRadius: HozzMetrics.buttonRadius,
                    style: .continuous
                )
            )
            // Opacity on the whole control, not a second colour. A disabled or
            // pressed state is a state, and both platforms and CSS express it
            // the same way, so it does not need a token of its own.
            .opacity(
                configuration.isPressed
                    ? HozzMetrics.pressedOpacity
                    : (isEnabled ? 1 : HozzMetrics.disabledOpacity)
            )
    }
}

/// The one unfilled button in the app.
public struct HozzQuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    private let tone: HozzTone

    public init(tone: HozzTone = .action) {
        self.tone = tone
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tone.textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                tone.well,
                in: RoundedRectangle(
                    cornerRadius: HozzMetrics.buttonRadius,
                    style: .continuous
                )
            )
            .opacity(
                configuration.isPressed
                    ? HozzMetrics.pressedOpacity
                    : (isEnabled ? 1 : HozzMetrics.disabledOpacity)
            )
    }
}

extension ButtonStyle where Self == HozzFilledButtonStyle {
    public static var hozzFilled: HozzFilledButtonStyle { HozzFilledButtonStyle() }
}

extension ButtonStyle where Self == HozzQuietButtonStyle {
    public static var hozzQuiet: HozzQuietButtonStyle { HozzQuietButtonStyle() }

    public static func hozzQuiet(tone: HozzTone) -> HozzQuietButtonStyle {
        HozzQuietButtonStyle(tone: tone)
    }
}

// MARK: - Forms

extension View {
    /// Puts a `List` or `Form` on the Hozz page instead of the system's grey
    /// one, and gives its rows the card tone.
    ///
    /// Used only where the screen is genuinely a set of controls — a picker, a
    /// text field, a switch. Rebuilding those by hand would mean reimplementing
    /// what iOS already does correctly, and getting keyboard handling and
    /// accessibility subtly wrong in the process. Everything that is content
    /// rather than input uses ``HozzScreen`` instead.
    public func hozzFormChrome() -> some View {
        scrollContentBackground(.hidden)
            .background(HozzSurface())
            .tint(HozzPalette.blue)
    }

    /// The card tone under a `Form` or `List` section's rows.
    public func hozzFormRows() -> some View {
        listRowBackground(HozzPalette.cardTop)
            .listRowSeparatorTint(HozzPalette.lineSoft)
    }
}

extension Text {
    /// A `Form` or `List` section header, in the same voice as the label over
    /// a ``HozzSection``.
    public func hozzFormHeader() -> some View {
        hozzLabel()
            .textCase(.uppercase)
    }

    /// The sentence under a `Form` or `List` section.
    public func hozzFormFooter() -> some View {
        hozzCaption()
    }
}

// MARK: - More type

extension Text {
    /// A section or card heading inside the page.
    public func hozzHeading(size: CGFloat = 20) -> Text {
        font(.system(size: size, weight: .semibold))
            .foregroundColor(HozzPalette.ink)
    }

    /// Ordinary running text.
    public func hozzBody(size: CGFloat = 14) -> Text {
        font(.system(size: size))
            .foregroundColor(HozzPalette.inkSoft)
    }
}
