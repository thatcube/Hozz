import HozzHealth
import HozzUI
import SwiftUI

/// What Hozz is, what it promises, and where the code lives.
struct AboutView: View {
    var body: some View {
        HozzScreen {
            introduction

            HozzSection("What Hozz promises") {
                HozzNoteCard {
                    HozzNote(
                        "Nothing leaves this iPhone until you add a destination",
                        icon: .shieldLock,
                        tone: .action
                    )
                    HozzNote(
                        "No subscription, paywall, account, or analytics",
                        icon: .heartHandshake,
                        tone: .action
                    )
                    HozzNote(
                        "Credentials stay in this iPhone's Keychain",
                        icon: .key,
                        tone: .action
                    )
                    HozzNote(
                        "Every record, with no gaps and no duplicates",
                        icon: .circleCheck,
                        tone: .action
                    )
                    HozzNote(
                        "Honest about anything it cannot prove",
                        icon: .eye,
                        tone: .action
                    )
                }
            }

            HozzSection("Coverage") {
                HozzNoteCard {
                    CoverageRow("Quantity and category samples", available: true)
                    CoverageRow("Basic workout records", available: true)
                    CoverageRow("Workout routes", available: true)
                    CoverageRow("Electrocardiograms", available: true)
                    CoverageRow("Audiograms", available: true)
                    CoverageRow("State of Mind", available: true)
                    CoverageRow("Medication doses", available: true)
                    CoverageRow("Health characteristics", available: true)
                    CoverageRow("Historical deletions", available: true)
                    // Driven by the build rather than written down, so it stays
                    // true whichever build someone is holding.
                    CoverageRow(
                        "Health records",
                        available: ClinicalRecordsSupport.isBuiltIn
                    )
                    CoverageRow(
                        "Correlations and documents",
                        available: false
                    )
                }
            }

            HozzSection {
                Link(destination: HozzLinks.source) {
                    HozzRow("Source code", icon: .github, isProminent: true) {
                        HozzIconView(.externalLink, size: 14)
                            .foregroundStyle(HozzPalette.inkMuted)
                    }
                }
                Link(destination: HozzLinks.sponsors) {
                    HozzRow(
                        "Support development",
                        icon: .heartHandshake,
                        isProminent: true
                    ) {
                        HozzIconView(.externalLink, size: 14)
                            .foregroundStyle(HozzPalette.inkMuted)
                    }
                }
                Link(destination: HozzLinks.developer) {
                    HozzRow("More free apps", icon: .world, isProminent: true) {
                        HozzIconView(.externalLink, size: 14)
                            .foregroundStyle(HozzPalette.inkMuted)
                    }
                }
            }

            Text("Icons by Tabler, used under the MIT licence.")
                .hozzCaption()
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            HozzIconView(.heart, size: 32)
                .foregroundStyle(HozzPalette.blue)
            Text("Your Health data, wherever you want it")
                .hozzDisplay(size: 26)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "Free and open source, with no subscription, no account, "
                + "and no server of ours in the middle."
            )
            .hozzBody()
            .fixedSize(horizontal: false, vertical: true)
        }
        .hozzCard(padding: 22)
    }
}
