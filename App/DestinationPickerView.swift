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
    @State private var browsing: BrowsingState = .idle
    @State private var known: SharedReceiver?

    /// Everything worth offering: what Bonjour found, plus the computer this
    /// person already set up, which may not be discoverable on this network.
    private var computers: [DiscoveredReceiver] {
        var all = discovered
        if let known, !known.endpoints.isEmpty,
           !all.contains(where: { known.endpoints.contains($0.url) }) {
            all.append(
                DiscoveredReceiver(
                    id: known.name,
                    name: known.name,
                    // A placeholder; the working address is chosen by probing
                    // when the user taps, because which one is reachable
                    // depends entirely on where the phone is right now.
                    url: known.endpoints[0]
                )
            )
        }
        return all
    }

    private let browser = ReceiverBrowser()
    private let pairing = ReceiverPairing()

    var body: some View {
        List {
            computersSection

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
            await browser.onStateChange { state in
                Task { @MainActor in browsing = state }
            }
            await browser.start()
            // A computer this person has already set up appears even when the
            // network refuses to carry mDNS, which many do.
            known = SharedReceiverStore(
                accessGroup: SharedReceiverStore.resolvedAccessGroup()
            ).published()
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
            if computers.isEmpty {
                emptyRow
            }
            ForEach(computers) { receiver in
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
            Text(footerText)
        }
    }

    /// Never renders nothing.
    ///
    /// An empty section is indistinguishable from a feature that does not
    /// exist, which is exactly how this looked: no computer, no explanation,
    /// no way to tell whether Hozz was even looking.
    @ViewBuilder
    private var emptyRow: some View {
        switch browsing {
        case .denied:
            Label {
                Text("Hozz needs permission to see this network")
            } icon: {
                HozzIconView(.alertTriangle, size: 20)
            }
            .foregroundStyle(.secondary)
        case .failed:
            Label("Could not search this network", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
        case .idle, .searching:
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking for computers…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footerText: String {
        switch browsing {
        case .denied:
            return "Allow Hozz to find devices on your local network in "
                + "Settings > Hozz, then come back. You can also add your "
                + "computer by web address instead."
        case .failed(let reason):
            return reason
        case .idle, .searching:
            return computers.isEmpty
                ? "Open Hozz on your Mac and it will appear here. Nothing to "
                    + "type, and nothing to copy across."
                : "Tap to connect. Hozz sets up the address and the token for "
                    + "you — nothing to copy across."
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
            // Try the address Bonjour just found first — it is known good on
            // this network — then everything the computer published about
            // itself. Saving an address without checking it is how a setup
            // completes happily and then times out forever.
            var ordered = [receiver.url]
            ordered.append(contentsOf: known.endpoints.filter { $0 != receiver.url })

            if let reachable = await ReceiverProbe().firstReachable(among: ordered) {
                await save(name: known.name, url: reachable, token: known.token)
                return
            }
            pairingError = """
                \(known.name) did not answer at any of its known addresses. \
                Make sure Hozz is open on it and both devices are on the same \
                network.
                """
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
