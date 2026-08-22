import HozzHealth
import SwiftUI

struct RootView: View {
    private let healthDataAvailable: Bool

    init(healthDataAvailable: Bool = HealthKitAvailability.isAvailable) {
        self.healthDataAvailable = healthDataAvailable
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    ExportLedgerHero()
                    PrivacyPromiseSection()
                    FoundationStatusSection(healthDataAvailable: healthDataAvailable)
                    ProjectLinksSection()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(HozzPalette.canvas.ignoresSafeArea())
            .navigationTitle("Hozz")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ExportLedgerHero: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ExportPathMark()

            VStack(alignment: .leading, spacing: 8) {
                Text("Your health data.\nYour destination.")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)

                Text("No account, analytics, subscription, or relay between the two.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.82))
            }

            HStack(spacing: 8) {
                PrivacyChip(title: "On device", symbol: "iphone")
                PrivacyChip(title: "Open source", symbol: "chevron.left.forwardslash.chevron.right")
                PrivacyChip(title: "Free", symbol: "heart")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(
            LinearGradient(
                colors: [HozzPalette.ink, HozzPalette.deepWater],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .shadow(color: HozzPalette.ink.opacity(0.16), radius: 28, y: 14)
    }
}

private struct ExportPathMark: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.text.square.fill")
                .font(.title2)

            Rectangle()
                .fill(.white.opacity(0.7))
                .frame(height: 1)
                .overlay(alignment: .trailing) {
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                }

            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.title2)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health data moves directly to your destination")
    }
}

private struct PrivacyChip: View {
    let title: LocalizedStringResource
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.12), in: Capsule())
            .foregroundStyle(.white)
    }
}

private struct PrivacyPromiseSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Built around privacy")
                .font(.title2.weight(.bold))

            VStack(spacing: 0) {
                PromiseRow(
                    symbol: "network.slash",
                    title: "No developer cloud",
                    detail: "Hozz never routes your data through infrastructure operated by its maintainer."
                )
                Divider().padding(.leading, 48)
                PromiseRow(
                    symbol: "person.crop.circle.badge.xmark",
                    title: "No account",
                    detail: "Your destinations and credentials stay under your control."
                )
                Divider().padding(.leading, 48)
                PromiseRow(
                    symbol: "checkmark.seal",
                    title: "Honest receipts",
                    detail: "Exports report what HealthKit returned and what could not be verified."
                )
            }
            .background(HozzPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

private struct PromiseRow: View {
    let symbol: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(HozzPalette.action)
                .frame(width: 34, height: 34)
                .background(HozzPalette.action.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }
}

private struct FoundationStatusSection: View {
    let healthDataAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Foundation status")
                .font(.title2.weight(.bold))

            HStack(alignment: .top, spacing: 14) {
                Image(systemName: healthDataAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(healthDataAvailable ? HozzPalette.success : .red)

                VStack(alignment: .leading, spacing: 4) {
                    Text(healthDataAvailable ? "HealthKit is available" : "HealthKit is unavailable")
                        .font(.headline)
                    Text("The reviewed acquisition engine is under construction. Hozz will not request partial access or pretend a small demo is a complete exporter.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HozzPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

private struct ProjectLinksSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Free and open source")
                .font(.title2.weight(.bold))

            VStack(spacing: 0) {
                ProjectLinkRow(
                    title: "Source code",
                    subtitle: "Follow development or contribute",
                    symbol: "chevron.left.forwardslash.chevron.right",
                    destination: HozzLinks.source
                )
                Divider().padding(.leading, 48)
                ProjectLinkRow(
                    title: "Support development",
                    subtitle: "Optional donations via GitHub Sponsors",
                    symbol: "heart.fill",
                    destination: HozzLinks.sponsors
                )
                Divider().padding(.leading, 48)
                ProjectLinkRow(
                    title: "More free apps",
                    subtitle: "Plozz, Mozz, and Twozz",
                    symbol: "square.grid.2x2",
                    destination: HozzLinks.developer
                )
            }
            .background(HozzPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

private struct ProjectLinkRow: View {
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    let symbol: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .foregroundStyle(HozzPalette.action)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum HozzLinks {
    static let source = URL(string: "https://github.com/thatcube/hozz")!
    static let sponsors = URL(string: "https://github.com/sponsors/thatcube")!
    static let developer = URL(string: "https://github.com/thatcube")!
}

enum HozzPalette {
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color(red: 0.04, green: 0.15, blue: 0.20)
    static let deepWater = Color(red: 0.02, green: 0.38, blue: 0.42)
    static let action = Color(red: 0.00, green: 0.45, blue: 0.48)
    static let success = Color(red: 0.12, green: 0.58, blue: 0.38)
}

#Preview {
    RootView(healthDataAvailable: true)
}
