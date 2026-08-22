import SwiftUI
import UniformTypeIdentifiers
import HozzReceive

/// The pairing screen: everything needed to point a phone at this computer.
struct ConnectView: View {
    let services: MacServices
    @State private var didCopyToken = false
    @State private var didCopyURL = false
    @State private var isChoosingFolder = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                folderSection

                switch services.status {
                case .starting:
                    ProgressView("Starting the receiver…")
                case .failed(let reason):
                    failure(reason)
                case .ready:
                    connectionStatus
                    if services.devices.isEmpty {
                        pairing
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Connect")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Receive Health data on this Mac")
                .font(.title2.weight(.semibold))
            Text(
                """
                Your phone sends directly to this computer over your own \
                network. Nothing goes through a server, and nothing leaves \
                your devices.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The path that does not depend on the network allowing anything.
    ///
    /// Offered first, and described plainly, because receiving over the local
    /// network needs the router not to isolate clients and the firewall to
    /// admit an app it does not recognise. Neither is something a person can
    /// reasonably be asked to arrange, and macOS refuses silently — the app
    /// looks like it is running and simply never receives anything.
    private var folderSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: services.watchedFolder == nil
                        ? "folder.badge.plus"
                        : "folder.fill.badge.checkmark")
                        .font(.title2)
                        .foregroundStyle(services.watchedFolder == nil ? Color.secondary : Color.green)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(services.watchedFolder == nil
                            ? "Receive from a folder"
                            : "Watching a folder")
                            .font(.body.weight(.semibold))
                        Text(folderDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                HStack {
                    Button(services.watchedFolder == nil ? "Choose a folder…" : "Change…") {
                        isChoosingFolder = true
                    }
                    .buttonStyle(.borderedProminent)

                    if services.watchedFolder != nil {
                        Button("Stop watching") {
                            Task { await services.stopWatchingFolder() }
                        }
                    }
                }
            }
            .padding(8)
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
            return """
                \(folder.lastPathComponent) — anything your iPhone writes here \
                is read automatically.
                """
        }
        return """
            Point your iPhone at a folder that syncs to this Mac — iCloud Drive, \
            Dropbox, anything — and pick the same folder here. This works from \
            anywhere, including cellular, and needs nothing from your network.
            """
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
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.title2)
                    .foregroundStyle(statusColour)

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.body.weight(.semibold))
                    Text(statusDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if services.devices.count > 1 {
                        ForEach(services.devices.dropFirst()) { device in
                            Text("\(device.name) — last \(Self.relative(device.lastSeenAt))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
            }
            .padding(8)
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
        guard latest != nil else {
            return .secondary
        }
        return isRecent ? .green : .orange
    }

    private var statusTitle: String {
        guard let latest else {
            return "No data received yet"
        }
        return isRecent
            ? "Receiving from \(latest.name)"
            : "Nothing new from \(latest.name)"
    }

    private var statusDetail: String {
        guard let latest else {
            return """
                This Mac is listening. Open Hozz on your iPhone, add a \
                destination, and pick this computer.
                """
        }
        let count = services.totalRecords.formatted()
        let when = Self.relative(latest.lastSeenAt)
        if isRecent {
            return "\(count) records · last arrived \(when)"
        }
        return """
            \(count) records · last arrived \(when). That is normal if the \
            phone has been away or has nothing new; iOS decides when Hozz runs.
            """
    }

    private static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    private func failure(_ reason: String) -> some View {
        GroupBox {
            Label(reason, systemImage: "exclamationmark.triangle")
                .padding(6)
        }
    }

    @ViewBuilder
    private var pairing: some View {
        GroupBox("On your iPhone") {
            VStack(alignment: .leading, spacing: 14) {
                step(1, "Open Hozz, go to Sync, and add a destination.")
                step(2, "Choose “This Mac” if it appears, or paste the address below.")
                step(3, "Paste the token as the authorization value.")
            }
            .padding(8)
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

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    """
                    This Mac is advertising itself as “Hozz on \
                    \(services.computerName)”, so the phone can usually find it \
                    without the address.
                    """,
                    systemImage: "bonjour"
                )
                if services.sharedWithOtherDevices == false {
                    Label(
                        """
                        This Mac could not tell your other devices about itself \
                        through iCloud, so it may not appear on your iPhone by \
                        name. The address above still works.
                        """,
                        systemImage: "exclamationmark.triangle"
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }

        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            Text(
                """
                The token stops anything else on your network sending or \
                reading data. Treat it like a password.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.tint))
            Text(text)
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
        GroupBox(title) {
            HStack {
                Text(isSecret ? String(repeating: "•", count: 24) : value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(copied ? "Copied" : "Copy", action: action)
                    .buttonStyle(.borderedProminent)
            }
            .padding(6)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
