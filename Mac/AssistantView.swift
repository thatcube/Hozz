import SwiftUI
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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ask about your own health data")
                        .font(.title2.weight(.semibold))
                    Text(
                        """
                        Hozz can expose the data on this Mac to an AI assistant \
                        that supports the Model Context Protocol, so you can ask \
                        questions in plain language. The assistant reads from \
                        this computer only — your data is never uploaded by Hozz.
                        """
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                GroupBox("Add this to your assistant's MCP configuration") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(configuration)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        Button(didCopy ? "Copied" : "Copy configuration") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(configuration, forType: .string)
                            didCopy = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(8)
                }

                GroupBox("What it can do") {
                    VStack(alignment: .leading, spacing: 12) {
                        capability(
                            "List what you have",
                            "Every type received, how many records, and the dates covered."
                        )
                        capability(
                            "Summarise trends",
                            "Totals and averages by hour, day, week or month over any range."
                        )
                        capability(
                            "Look at individual readings",
                            "Specific samples when a single measurement matters."
                        )
                    }
                    .padding(8)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            "It can only read. Nothing an assistant does can change or delete your data.",
                            systemImage: "lock.shield"
                        )
                        Label(
                            """
                            Whatever the assistant reads goes wherever that \
                            assistant sends it. If it runs in the cloud, your \
                            health data goes to the cloud — that is its \
                            behaviour, not Hozz's, and it is worth knowing \
                            before you connect one.
                            """,
                            systemImage: "exclamationmark.triangle"
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                }

                if services.totalRecords == 0 {
                    Label(
                        "No data has arrived yet, so an assistant would have nothing to read.",
                        systemImage: "tray"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Assistant")
    }

    private func capability(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body.weight(.medium))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A plain log of what the receiver has done, so "is it working" has an answer.
struct ActivityView: View {
    let services: MacServices

    var body: some View {
        Group {
            if services.events.isEmpty {
                ContentUnavailableView {
                    Label("No deliveries yet", systemImage: "clock")
                } description: {
                    Text("Every batch this Mac receives will be listed here.")
                }
            } else {
                List(services.events) { event in
                    HStack(spacing: 12) {
                        Image(systemName: symbol(for: event.outcome))
                            .foregroundStyle(colour(for: event.outcome))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(description(for: event.outcome))
                            Text(event.at.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
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
            return "Already had this batch, so nothing changed"
        case .connectionTest:
            return "Connection test succeeded"
        case .rejected(let reason):
            return "Rejected: \(reason)"
        }
    }

    private func symbol(for outcome: ReceiverEvent.Outcome) -> String {
        switch outcome {
        case .stored: "checkmark.circle"
        case .duplicate: "equal.circle"
        case .connectionTest: "bolt.horizontal.circle"
        case .rejected: "exclamationmark.circle"
        }
    }

    private func colour(for outcome: ReceiverEvent.Outcome) -> Color {
        switch outcome {
        case .stored: .green
        case .duplicate, .connectionTest: .secondary
        case .rejected: .orange
        }
    }
}
