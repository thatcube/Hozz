import HozzUI
import SwiftUI

/// What Hozz is, what it promises, and where the code lives.
struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HozzIconView(.heart, size: 36)
                        .foregroundStyle(HozzPalette.action)
                    Text("Your Health data, wherever you want it")
                        .font(.title2.bold())
                    Text(
                        "Free and open source, with no subscription, no account, "
                        + "and no server of ours in the middle."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section("What Hozz promises") {
                HozzLabel("Nothing leaves this iPhone until you add a destination", icon: .shieldLock)
                HozzLabel("No subscription, paywall, account, or analytics", icon: .heartHandshake)
                HozzLabel("Credentials stay in this iPhone's Keychain", icon: .key)
                HozzLabel("Every record, with no gaps and no duplicates", icon: .circleCheck)
                HozzLabel("Honest about anything it cannot prove", icon: .eye)
            }
            .font(.subheadline)

            Section("Coverage") {
                CoverageRow("Quantity and category samples", available: true)
                CoverageRow("Basic workout records", available: true)
                CoverageRow("Workout routes", available: true)
                CoverageRow("Electrocardiograms", available: true)
                CoverageRow("Audiograms", available: true)
                CoverageRow("State of Mind", available: true)
                CoverageRow("Health characteristics", available: true)
                CoverageRow("Historical deletions", available: true)
                CoverageRow(
                    "Correlations, documents, and clinical records",
                    available: false
                )
            }

            Section {
                Link(destination: HozzLinks.source) {
                    HozzLabel("Source code", icon: .github)
                }
                Link(destination: HozzLinks.sponsors) {
                    HozzLabel("Support development", icon: .heartHandshake)
                }
                Link(destination: HozzLinks.developer) {
                    HozzLabel("More free apps", icon: .world)
                }
            }

            Section {
                Text("Icons by Tabler, used under the MIT licence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
    }
}
