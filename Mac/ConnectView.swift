import SwiftUI
import UniformTypeIdentifiers
import HozzReceive
import HozzUI

/// The pairing screen: everything needed to point a phone at this computer.
struct ConnectView: View {
    let services: MacServices
    @State private var didCopyToken = false
    @State private var didCopyURL = false
    @State private var isChoosingFolder = false

    var body: some View {
        HozzDesktopPage {
            header
            folderSection

            switch services.status {
            case .starting:
                HozzPanel {
                    ProgressView("Starting receiver…")
                }
            case .failed(let reason):
                failure(reason)
            case .ready:
                connectionStatus
                if services.devices.isEmpty {
                    pairing
                }
            }
        }
        .navigationTitle("Connect")
    }

    private var header: some View {
        HozzPageHeader(
            "Receive from iPhone",
            subtitle: "Use a synced folder or local network. Hozz never relays your data."
        )
    }

    /// The path that does not depend on the network allowing anything.
    ///
    /// Offered first, and described plainly, because receiving over the local
    /// network needs the router not to isolate clients and the firewall to
    /// admit an app it does not recognise. Neither is something a person can
    /// reasonably be asked to arrange, and macOS refuses silently — the app
    /// looks like it is running and simply never receives anything.
    private var folderSection: some View {
        HozzPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: services.watchedFolder == nil
                        ? "folder.badge.plus"
                        : "folder.fill.badge.checkmark")
                        .font(.title2)
                        .foregroundStyle(
                            services.watchedFolder == nil
                                ? HozzPalette.inkMuted
                                : HozzPalette.blue
                        )
                        .frame(width: 38, height: 38)
                        .background(
                            services.watchedFolder == nil
                                ? HozzPalette.neutralWell
                                : HozzPalette.iconWell,
                            in: Circle()
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(services.watchedFolder == nil
                            ? "Synced folder"
                            : "Watching \(services.watchedFolder?.lastPathComponent ?? "folder")")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(HozzPalette.ink)
                        Text(folderDescription)
                            .font(.callout)
                            .foregroundStyle(HozzPalette.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                HStack {
                    Button(services.watchedFolder == nil ? "Choose a folder…" : "Change…") {
                        isChoosingFolder = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HozzPalette.actionFill)

                    if services.watchedFolder != nil {
                        Button("Stop watching") {
                            Task { await services.stopWatchingFolder() }
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder]
        ) { result in
            guard case .success(let url) = result else {
                return
            }
            Task { await services.watchFolder(url) }
        }
    }

    private var folderDescription: String {
        if let folder = services.watchedFolder {
            return "\(folder.lastPathComponent) imports new files automatically."
        }
        return "Choose the same synced folder on iPhone and Mac. It works from anywhere."
    }

    /// Says what is actually known: when data last arrived, and from where.
    ///
    /// Deliberately not phrased as "connected". Deliveries are separate HTTP
    /// requests with nothing held open in between, so there is no connection to
    /// be in — a phone that synced a minute ago and one that has been switched
    /// off since look identical from here. Reporting when data last arrived is
    /// both true and the thing the user actually wants to know.
    @ViewBuilder
    private var connectionStatus: some View {
        HozzPanel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.title2)
                    .foregroundStyle(statusColour)
                    .frame(width: 38, height: 38)
                    .background(statusTone.well, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(HozzPalette.ink)
                    Text(statusDetail)
                        .font(.callout)
                        .foregroundStyle(HozzPalette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)

                    if services.devices.count > 1 {
                        ForEach(services.devices.dropFirst()) { device in
                            Text("\(device.name) — last \(Self.relative(device.lastSeenAt))")
                                .font(.caption)
                                .foregroundStyle(HozzPalette.inkMuted)
                        }
                    }
                }
                Spacer()
            }
        }
    }

    /// How long ago counts as "recently".
    ///
    /// Chosen to match the cadence Hozz actually syncs at: HealthKit caps most
    /// background delivery at hourly, so a gap of a couple of hours is ordinary
    /// and not worth alarming anyone about.
    private static let recentInterval: TimeInterval = 2 * 60 * 60

    private var latest: KnownDevice? {
        services.devices.max { $0.lastSeenAt < $1.lastSeenAt }
    }

    private var isRecent: Bool {
        guard let latest else {
            return false
        }
        return Date().timeIntervalSince(latest.lastSeenAt) < Self.recentInterval
    }

    private var statusSymbol: String {
        guard latest != nil else {
            return "iphone.badge.exclamationmark"
        }
        return isRecent ? "checkmark.circle.fill" : "clock.badge.exclamationmark"
    }

    private var statusColour: Color {
        statusTone.color
    }

    private var statusTone: HozzTone {
        guard latest != nil else { return .neutral }
        return isRecent ? .positive : .warning
    }

    private var statusTitle: String {
        guard let latest else {
            return "Waiting for iPhone"
        }
        return isRecent
            ? "Receiving from \(latest.name)"
            : "Nothing new from \(latest.name)"
    }

    private var statusDetail: String {
        guard let latest else {
            return "Add this Mac as a destination on iPhone."
        }
        let count = services.totalRecords.formatted()
        let when = Self.relative(latest.lastSeenAt)
        if isRecent {
            return "\(count) records · last \(when)"
        }
        return "\(count) records · last \(when). iOS sends when it can."
    }

    private static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    private func failure(_ reason: String) -> some View {
        HozzPanel {
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(HozzPalette.warning)
        }
    }

    @ViewBuilder
    private var pairing: some View {
        HozzPanel(title: "On your iPhone") {
            VStack(alignment: .leading, spacing: 14) {
                step(1, "Open Automatic, add a destination, and choose this Mac.")
                step(2, "If it does not appear, use the address and token below.")
            }
        }

        if let url = services.endpointURL {
            copyRow(
                title: "Address",
                value: url,
                copied: didCopyURL,
                action: {
                    copy(url)
                    didCopyURL = true
                }
            )
        }

        copyRow(
            title: "Token",
            value: services.token,
            copied: didCopyToken,
            isSecret: true,
            action: {
                copy(services.token)
                didCopyToken = true
            }
        )

        HozzPanel {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Visible to iPhone as “Hozz on \(services.computerName)”.",
                    systemImage: "bonjour"
                )
                if services.sharedWithOtherDevices == false {
                    Label(
                        "iCloud discovery is unavailable. Use the address above.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(HozzPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            Text("Treat the token like a password.")
            .font(.callout)
            .foregroundStyle(HozzPalette.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(HozzPalette.onAction)
                .frame(width: 20, height: 20)
                .background(Circle().fill(HozzPalette.actionFill))
            Text(text)
                .foregroundStyle(HozzPalette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyRow(
        title: String,
        value: String,
        copied: Bool,
        isSecret: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HozzPanel(verbatimTitle: title) {
            HStack {
                Text(isSecret ? String(repeating: "•", count: 24) : value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(copied ? "Copied" : "Copy", action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(HozzPalette.actionFill)
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
