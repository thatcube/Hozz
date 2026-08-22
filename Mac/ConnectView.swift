import SwiftUI
import HozzReceive

/// The pairing screen: everything needed to point a phone at this computer.
struct ConnectView: View {
    let services: MacServices
    @State private var didCopyToken = false
    @State private var didCopyURL = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

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

    /// Says plainly whether anything has actually connected.
    ///
    /// Without this the screen only ever explained how to connect, so there was
    /// no way to tell a working setup from a broken one — the user is left
    /// watching an instruction list and guessing.
    @ViewBuilder
    private var connectionStatus: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: services.devices.isEmpty
                    ? "iphone.badge.exclamationmark"
                    : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(services.devices.isEmpty ? Color.secondary : Color.green)

                VStack(alignment: .leading, spacing: 4) {
                    if let device = services.devices.first {
                        Text("Connected to \(device.name)")
                            .font(.body.weight(.semibold))
                        Text(receivedSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Waiting for your iPhone")
                            .font(.body.weight(.semibold))
                        Text(
                            "This Mac is listening. Open Hozz on your iPhone, "
                            + "add a destination, and pick this computer."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            .padding(8)
        }
    }

    private var receivedSummary: String {
        guard services.totalRecords > 0 else {
            return "Nothing has arrived yet. It will appear here when it does."
        }
        let count = services.totalRecords.formatted()
        guard let last = services.lastReceivedAt else {
            return "\(count) records received."
        }
        return "\(count) records · last \(last.formatted(.relative(presentation: .named)))"
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
            Label(
                """
                This Mac is advertising itself as “Hozz on \
                \(services.computerName)”, so the phone can usually find it \
                without the address.
                """,
                systemImage: "bonjour"
            )
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
