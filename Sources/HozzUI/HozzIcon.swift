import SwiftUI

/// Every icon Hozz draws, named once.
///
/// These are Tabler icons (MIT, vendored in `App/Vendor`), shipped as vector
/// assets with template rendering so they take the surrounding foreground
/// colour and stay sharp at any size. Referring to them through an enum rather
/// than a string means a typo is a build error instead of an invisible blank
/// space at runtime.
public enum HozzIcon: String, CaseIterable, Sendable {
    case heart
    case heartHandshake = "heart-handshake"
    case activity
    case cloudUpload = "cloud-upload"
    case cloudCheck = "cloud-check"
    case cloudOff = "cloud-off"
    case folder
    case folderPlus = "folder-plus"
    case folderOpen = "folder-open"
    case api
    case plugConnected = "plug-connected"
    case world
    case server
    case settings
    case adjustments
    case check
    case circleCheck = "circle-check"
    case alertTriangle = "alert-triangle"
    case infoCircle = "info-circle"
    case lock
    case lockOpen = "lock-open"
    case clock
    case refresh
    case rotate
    case play = "player-play"
    case pause = "player-pause"
    case deviceMobile = "device-mobile"
    case deviceDesktop = "device-desktop"
    case database
    case fileText = "file-text"
    case fileCSV = "file-type-csv"
    case fileCode = "file-code"
    case table
    case code
    case chartLine = "chart-line"
    case chartDots = "chart-dots"
    case shieldLock = "shield-lock"
    case shieldCheck = "shield-check"
    case trash
    case plus
    case chevronRight = "chevron-right"
    case chevronDown = "chevron-down"
    case download
    case upload
    case github = "brand-github"
    case barbell
    case moon
    case flame
    case footsteps
    case walk
    case run
    case shoe
    case close = "x"
    case helpCircle = "help-circle"
    case wifiOff = "wifi-off"
    case battery
    case calendar
    case key
    case link
    case send
    case listCheck = "list-check"
    case progress
    case hourglass
    case bell
    case eye
    case eyeOff = "eye-off"
    case filter
    case search
    case dots
    case externalLink = "external-link"
    case copy
    case sparkles
    case arrowRight = "arrow-right"
    case arrowLeft = "arrow-left"
    case home
    case lungs
    case droplet
    case scale
    case ruler
    case bed
}

public extension Image {
    /// Builds a template image for a Hozz icon.
    init(_ icon: HozzIcon) {
        self.init(icon.rawValue)
        self = self.renderingMode(.template)
    }
}

/// An icon sized to sit alongside text.
public struct HozzIconView: View {
    private let icon: HozzIcon
    private let size: CGFloat

    public init(_ icon: HozzIcon, size: CGFloat = 20) {
        self.icon = icon
        self.size = size
    }

    public var body: some View {
        Image(icon.rawValue)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

/// A label that pairs a Tabler icon with text, replacing SwiftUI's `Label`
/// where an SF Symbol would otherwise be used.
public struct HozzLabel<Title: View>: View {
    private let icon: HozzIcon
    private let size: CGFloat
    private let title: Title

    public init(
        _ icon: HozzIcon,
        size: CGFloat = 20,
        @ViewBuilder title: () -> Title
    ) {
        self.icon = icon
        self.size = size
        self.title = title()
    }

    public var body: some View {
        HStack(spacing: 10) {
            HozzIconView(icon, size: size)
            title
        }
    }
}

public extension HozzLabel where Title == Text {
    init(_ titleKey: LocalizedStringKey, icon: HozzIcon, size: CGFloat = 20) {
        self.init(icon, size: size) { Text(titleKey) }
    }
}
