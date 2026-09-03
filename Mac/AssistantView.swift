import SwiftUI
import HozzUI
import HozzReceive

/// Sets up an AI assistant to answer questions about the received data.
struct AssistantView: View {
    let services: MacServices
    @State private var didCopy = false

    private var configuration: String {
        let executable = Bundle.main.bundleURL
            .appending(path: "Contents/MacOS/hozz-mcp")
            .path
        // The path is passed explicitly because the assistant launches this
        // tool outside Hozz's sandbox, where "Application Support" resolves to
        // a different, empty directory.
        return """
        {
          "mcpServers": {
            "hozz": {
              "command": "\(executable)",
              "args": ["--data-dir", "\(services.dataDirectory.path)"]
            }
          }
        }
        """
    }

    var body: some View {
        HozzDesktopPage {
            HozzPageHeader(
                "Ask your data",
                subtitle: "Connect an MCP assistant to the archive on this Mac."
            )

            HozzPanel(title: "Configuration") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(configuration)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(HozzPalette.inkSoft)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            HozzPalette.air,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    Button(didCopy ? "Copied" : "Copy configuration") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configuration, forType: .string)
                        didCopy = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HozzPalette.actionFill)
                }
            }

            HozzPanel(title: "Capabilities") {
                VStack(alignment: .leading, spacing: 12) {
                    HozzNote("List types, record counts, and dates", icon: .listCheck)
                    HozzNote("Summarise trends by hour, day, week, or month", icon: .chartLine)
                    HozzNote("Read individual samples", icon: .search)
                }
            }

            HozzPanel {
                VStack(alignment: .leading, spacing: 12) {
                    HozzNote(
                        "Read-only: assistants cannot change or delete Hozz data.",
                        icon: .shieldLock
                    )
                    HozzNote(
                        "An assistant may send what it reads elsewhere. Check its privacy terms.",
                        icon: .alertTriangle,
                        tone: .warning
                    )
                }
            }

            if services.totalRecords == 0 {
                HozzPanel {
                    HozzNote("No data yet. Connect an iPhone first.", icon: .infoCircle)
                }
            }
        }
        .navigationTitle("Assistant")
    }
}

/// A plain log of what the receiver has done, so "is it working" has an answer.
struct ActivityView: View {
    let services: MacServices

    var body: some View {
        HozzDesktopPage {
            HozzPageHeader("Activity", subtitle: "Recent deliveries to this Mac.")

            if services.events.isEmpty {
                HozzPanel {
                    HozzNote("No deliveries yet.", icon: .clock)
                }
            } else {
                HozzPanel {
                    LazyVStack(spacing: 0) {
                        ForEach(services.events) { event in
                            HStack(spacing: 12) {
                                Image(systemName: symbol(for: event.outcome))
                                    .foregroundStyle(colour(for: event.outcome))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(description(for: event.outcome))
                                    Text(
                                        event.at.formatted(
                                            date: .abbreviated,
                                            time: .standard
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(HozzPalette.inkMuted)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
        }
        .navigationTitle("Activity")
    }

    private func description(for outcome: ReceiverEvent.Outcome) -> String {
        switch outcome {
        case .stored(let records, let deleted):
            var text = "Stored \(records) record\(records == 1 ? "" : "s")"
            if deleted > 0 {
                text += ", removed \(deleted)"
            }
            return text
        case .duplicate:
            return "Duplicate batch ignored"
        case .connectionTest:
            return "Connection test passed"
        case .rejected(let reason):
            return "Rejected: \(reason)"
        case .paired(let device):
            return "Connected \(device)"
        case .pairingRefused(let device):
            return "Refused \(device) — this Mac is already connected"
        }
    }

    private func symbol(for outcome: ReceiverEvent.Outcome) -> String {
        switch outcome {
        case .stored: "checkmark.circle"
        case .duplicate: "equal.circle"
        case .connectionTest: "bolt.horizontal.circle"
        case .rejected: "exclamationmark.circle"
        case .paired: "checkmark.seal"
        case .pairingRefused: "hand.raised"
        }
    }

    private func colour(for outcome: ReceiverEvent.Outcome) -> Color {
        switch outcome {
        case .stored, .paired: HozzPalette.positive
        case .duplicate, .connectionTest: HozzPalette.inkMuted
        case .rejected, .pairingRefused: HozzPalette.warning
        }
    }
}
