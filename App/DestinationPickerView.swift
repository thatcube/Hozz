import HozzDeliver
import UIKit
import HozzUI
import SwiftUI

/// Chooses what kind of destination to add.
///
/// Naming Home Assistant and MQTT separately matters even though one of them is
/// an HTTPS endpoint underneath. A capability nobody can find is not a
/// capability, and "how do I connect this to Home Assistant" is the question
/// people ask most about tools like this.
struct DestinationPickerView: View {
    let model: SyncViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: DestinationPreset?
    @State private var discovered: [DiscoveredReceiver] = []
    @State private var connecting: String?
    @State private var pairingError: String?

    private let browser = ReceiverBrowser()
    private let pairing = ReceiverPairing()

    var body: some View {
        List {
            if !discovered.isEmpty {
                computersSection
            }

            Section {
                ForEach(DestinationPreset.allCases) { preset in
                    Button {
                        chosen = preset
                    } label: {
                        HStack(spacing: 14) {
                            Image(preset.iconName)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 26, height: 26)
                                .foregroundStyle(
                                    preset.isRecommended ? HozzPalette.action : .secondary
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(preset.displayName)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if preset.isRecommended {
                                        Text("Easiest")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                HozzPalette.action.opacity(0.15),
                                                in: Capsule()
                                            )
                                            .foregroundStyle(HozzPalette.action)
                                    }
                                }
                                Text(preset.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                            HozzIconView(.chevronRight, size: 14)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Where should your Health data go?")
            } footer: {
                Text(
                    "Hozz has no default destination. Nothing leaves this "
                    + "iPhone until you add one."
                )
            }
        }
        .navigationTitle("Add a destination")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await browser.onChange { receivers in
                Task { @MainActor in discovered = receivers }
            }
            await browser.start()
        }
        .onDisappear { Task { await browser.stop() } }
        .alert(
            "Could not connect",
            isPresented: .init(
                get: { pairingError != nil },
                set: { if !$0 { pairingError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { pairingError = nil }
        } message: {
            Text(pairingError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .navigationDestination(item: $chosen) { preset in
            DestinationEditorView(
                model: model,
                destination: nil,
                preset: preset
            )
        }
    }

    /// Computers running Hozz on this network.
    ///
    /// Shown first, and without the user having to know that a Mac is a "web
    /// address" underneath. Something that only appears once you have guessed
    /// the right category is not discoverable at all.
    private var computersSection: some View {
        Section {
            ForEach(discovered) { receiver in
                Button {
                    Task { await connect(to: receiver) }
                } label: {
                    HStack(spacing: 14) {
                        HozzIconView(.deviceDesktop, size: 26)
                            .foregroundStyle(HozzPalette.action)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(receiver.name)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("Found on this network")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if connecting == receiver.id {
                            ProgressView()
                        } else {
                            HozzIconView(.chevronRight, size: 14)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(connecting != nil)
            }
        } header: {
            Text("Your computers")
        } footer: {
            Text(
                "Tap to connect. Hozz sets up the address and the token for "
                + "you — nothing to copy across."
            )
        }
    }

    /// Connects to a computer and saves a ready-to-use destination.
    ///
    /// If this person's own Mac already published its token to their iCloud
    /// Keychain, it is used directly — two devices on the same Apple account
    /// are already known to belong to the same person, which is far stronger
    /// evidence than anything that could be established over a home network.
    /// Only when that is unavailable does this fall back to pairing.
    private func connect(to receiver: DiscoveredReceiver) async {
        connecting = receiver.id
        defer { connecting = nil }

        if let known = SharedReceiverStore(
            accessGroup: SharedReceiverStore.resolvedAccessGroup()
        ).published() {
            await save(
                name: known.name,
                url: receiver.url,
                token: known.token
            )
            return
        }

        do {
            let result = try await pairing.pair(
                with: receiver.url,
                deviceName: await UIDevice.current.name
            )
            await save(
                name: result.name,
                url: receiver.url,
                token: result.token
            )
        } catch {
            pairingError = error.localizedDescription
        }
    }

    private func save(name: String, url: String, token: String) async {
        let destination = Destination(
            name: name,
            kind: .restAPI,
            format: .ndjson,
            cadence: .whenDataArrives,
            endpointURL: URL(string: url)
        )
        await model.save(destination, secret: token)
        dismiss()
    }
}
