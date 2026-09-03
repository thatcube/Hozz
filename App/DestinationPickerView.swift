import HozzCore
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
    @State private var known: [SharedReceiver] = []
    /// Which computers answered when asked, and at which address.
    ///
    /// A published record says where a computer was, never that it is still
    /// running — and a machine that has been shut down cannot withdraw its own
    /// record. So each is asked directly, and one that does not answer is shown
    /// as offline rather than offered as though tapping it would work.
    @State private var reachable: [String: String] = [:]
    @State private var checking = false
    /// Computers found by asking every address on the local network.
    @State private var scanned: [DiscoveredReceiver] = []

    /// Everything worth offering: what Bonjour found, plus the computer this
    /// person already set up, which may not be discoverable on this network.
    private var computers: [DiscoveredReceiver] {
        var all = discovered
        // Anything the sweep found is live by definition — it just answered.
        for computer in scanned where !all.contains(where: { $0.name == computer.name }) {
            all.append(computer)
        }
        // Every computer this person has opened Hozz on, not just the last one
        // to publish. A single record meant a second computer replaced the
        // first and only one could ever be offered.
        for computer in known where !computer.endpoints.isEmpty {
            guard !all.contains(where: { computer.endpoints.contains($0.url) }),
                  !all.contains(where: { $0.name == computer.name }) else {
                continue
            }
            all.append(
                DiscoveredReceiver(
                    id: computer.name,
                    name: computer.name,
                    // A placeholder; the working address is chosen by probing
                    // when the user taps, because which one is reachable
                    // depends entirely on where the phone is right now.
                    url: computer.endpoints[0]
                )
            )
        }
        // A computer that is already a destination is not on offer. Adding it
        // twice would deliver everything twice and give the user two entries
        // to keep in step for no benefit.
        return all.filter { !isAlreadyAdded($0) }
    }

    private func isAlreadyAdded(_ receiver: DiscoveredReceiver) -> Bool {
        model.summaries.contains { summary in
            let destination = summary.destination
            if destination.name == receiver.name {
                return true
            }
            guard let endpoint = destination.endpointURL?.absoluteString else {
                return false
            }
            if endpoint == receiver.url {
                return true
            }
            // The same computer may answer on several addresses, so a match on
            // any of the ones it published counts.
            return known.first { $0.name == receiver.name }?
                .endpoints.contains(endpoint) ?? false
        }
    }

    private let browser = ReceiverBrowser()
    private let pairing = ReceiverPairing()

    var body: some View {
        HozzScreen {
            computersSection

            HozzSection(
                "Choose a destination",
                footer: "No default. Nothing leaves until you add one."
            ) {
                ForEach(DestinationPreset.allCases) { preset in
                    Button {
                        chosen = preset
                    } label: {
                        PresetRow(preset: preset)
                    }
                    .buttonStyle(.plain)
                }
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
            ).publishedAll()
            await checkReachability()
            // Bonjour needs mDNS, and the shared record needs iCloud to have
            // synced. Neither is dependable, and when both come up empty the
            // user is left looking at a computer they can see is running. The
            // receiver's port is known, so the network can simply be asked.
            let found = await LocalNetworkScan(port: HozzService.defaultPort).scan()
            scanned = found.map {
                DiscoveredReceiver(id: $0.endpoint, name: $0.name, url: $0.endpoint)
            }
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
                    .tint(HozzPalette.blue)
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
        HozzSection("Your computers", footer: footerText) {
            if computers.isEmpty {
                emptyRow
            }
            ForEach(computers) { receiver in
                let isOnline = isOnline(receiver)
                Button {
                    Task { await connect(to: receiver) }
                } label: {
                    HozzRow(
                        receiver.name,
                        detail: status(for: receiver),
                        icon: .deviceDesktop,
                        tone: isOnline ? .action : .neutral
                    ) {
                        if connecting == receiver.id {
                            ProgressView().controlSize(.small)
                        } else if isOnline {
                            HozzChevron()
                        }
                    }
                    .opacity(isOnline ? 1 : 0.62)
                }
                .buttonStyle(.plain)
                // Offering a computer that cannot answer only produces a
                // failure the user could not have avoided.
                .disabled(connecting != nil || !isOnline)
            }
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
            HozzNoteCard {
                HozzNote(
                    "Hozz needs permission to see this network",
                    icon: .alertTriangle,
                    tone: .warning
                )
            }
        case .failed:
            HozzNoteCard {
                HozzNote("Could not search this network", icon: .wifiOff)
            }
        case .idle, .searching:
            HStack(spacing: 11) {
                ProgressView().controlSize(.small)
                Text("Looking for computers…").hozzCaption()
                Spacer(minLength: 0)
            }
            .hozzCard(
                padding: HozzMetrics.rowPadding,
                radius: HozzMetrics.rowRadius
            )
        }
    }

    private var footerText: String {
        switch browsing {
        case .denied:
            return "Allow Local Network access in Settings, or add a web address."
        case .failed(let reason):
            return reason
        case .idle, .searching:
            if !computers.isEmpty {
                return "Choose a Mac to connect automatically."
            }
            // Nothing left to offer because everything found is already set up
            // is a success, and should not read like a failure to find it.
            if !model.summaries.isEmpty {
                return "Every computer Hozz can see is already set up."
            }
            return "Open Hozz on your Mac to connect automatically."
        }
    }

    /// Asks every known computer whether it is actually running.
    ///
    /// Bonjour results are trusted without asking: the service was advertising
    /// a moment ago, which is the same evidence a probe would gather.
    private func checkReachability() async {
        checking = true
        defer { checking = false }

        let probe = ReceiverProbe(timeout: 2)
        var found: [String: String] = [:]
        for computer in known {
            if let working = await probe.firstReachable(among: computer.endpoints) {
                found[computer.name] = working
            }
        }
        reachable = found
    }

    private func isOnline(_ receiver: DiscoveredReceiver) -> Bool {
        // Anything Bonjour or the sweep just returned is live by definition.
        if discovered.contains(where: { $0.id == receiver.id })
            || scanned.contains(where: { $0.id == receiver.id }) {
            return true
        }
        return reachable[receiver.name] != nil
    }

    private func status(for receiver: DiscoveredReceiver) -> String {
        if discovered.contains(where: { $0.id == receiver.id })
            || scanned.contains(where: { $0.id == receiver.id }) {
            return "On this network"
        }
        if reachable[receiver.name] != nil {
            return "Ready"
        }
        return checking ? "Checking…" : "Offline"
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

        // Match the record to the computer that was tapped, rather than
        // assuming there is only one.
        let records = SharedReceiverStore(
            accessGroup: SharedReceiverStore.resolvedAccessGroup()
        ).publishedAll()
        if let known = records.first(where: { $0.name == receiver.name })
            ?? records.first(where: { $0.endpoints.contains(receiver.url) }) {
            // Try the address Bonjour just found first — it is known good on
            // this network — then everything the computer published about
            // itself. Saving an address without checking it is how a setup
            // completes happily and then times out forever.
            var ordered: [String] = []
            if let confirmed = reachable[receiver.name] {
                ordered.append(confirmed)
            }
            if !ordered.contains(receiver.url) {
                ordered.append(receiver.url)
            }
            ordered.append(contentsOf: known.endpoints.filter { !ordered.contains($0) })

            if let reachable = await ReceiverProbe().firstReachable(among: ordered) {
                await save(name: known.name, url: reachable, token: known.token)
                return
            }
            // Local network permission is by far the most common cause, and
            // it is invisible: every probe simply times out exactly as it
            // would if the computer were switched off. Naming it first saves
            // the user hunting for a network fault that is not there.
            // Report what was actually tried and what each address said.
            // Without this every failure reads the same regardless of cause.
            let probe = ReceiverProbe()
            var reasons: [String] = []
            for endpoint in ordered {
                if let reason = await probe.failureReason(for: endpoint) {
                    reasons.append(reason)
                }
            }
            pairingError = """
                \(known.name) did not answer.

                \(reasons.joined(separator: "\n\n"))
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

/// One kind of destination on offer.
private struct PresetRow: View {
    let preset: DestinationPreset

    var body: some View {
        HStack(spacing: 12) {
            Image(preset.iconName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
                .foregroundStyle(
                    preset.isRecommended ? HozzPalette.blue : HozzPalette.inkSoft
                )
                .frame(width: 30, height: 30)
                .background(
                    preset.isRecommended
                        ? HozzPalette.iconWell
                        : HozzPalette.neutralWell,
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(preset.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(HozzPalette.ink)
                    if preset.isRecommended {
                        Text("Easiest")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.4)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(HozzPalette.blueWash, in: Capsule())
                            .foregroundStyle(HozzPalette.actionText)
                    }
                }
                Text(preset.summary)
                    .hozzCaption()
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)
            HozzChevron()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hozzCard(padding: HozzMetrics.rowPadding, radius: HozzMetrics.rowRadius)
    }
}
