import Charts
import SwiftUI
import HozzReceive
import UniformTypeIdentifiers

/// Browse what has actually arrived, with a chart per type.
struct DataView: View {
    let services: MacServices
    @State private var selected: String?
    @State private var bucket: BucketSize = .day
    @State private var buckets: [AggregateBucket] = []
    @State private var isExporting = false

    var body: some View {
        Group {
            if services.summaries.isEmpty && services.characteristics.isEmpty {
                ContentUnavailableView {
                    Label("Nothing received yet", systemImage: "tray")
                } description: {
                    Text("Once your phone syncs, every type it sends appears here.")
                }
            } else {
                content
            }
        }
        .navigationTitle("Data")
        .task { await services.refresh() }
    }

    /// Deliberately an `HStack` and not an `HSplitView`.
    ///
    /// This view is already the detail column of a `NavigationSplitView`, and on
    /// macOS 26 nesting one split view inside another makes the two negotiate
    /// widths that cannot all hold at once. The window then re-runs the layout
    /// to satisfy them, each pass invalidating the last, until AppKit gives up
    /// inside `_postWindowNeedsUpdateConstraints` and the app is killed:
    ///
    ///     NSGenericException
    ///     -[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]
    ///     -[NSView _informContainerThatSubviewsNeedUpdateConstraints]  (x14)
    ///
    /// It took selecting a type to trigger, because an empty detail pane asks
    /// for nothing and a populated one asks for a minimum width. So the app
    /// opened cleanly, listed everything received, and died on the first click.
    ///
    /// The cost is that this divider no longer drags. That is a real loss and it
    /// is the right trade: the outer sidebar still resizes, and a pane the user
    /// cannot widen is better than a window that closes itself.
    private var content: some View {
        HStack(spacing: 0) {
            typeList
                .frame(width: 300)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var typeList: some View {
        List(selection: $selected) {
            // Above the measurements, because they are what the measurements
            // have to be read against: a resting heart rate of 48 means
            // something different at 34 than at 70.
            if !services.characteristics.isEmpty {
                Section("About you") {
                    ForEach(services.characteristics) { characteristic in
                        HStack {
                            Text(characteristic.displayName)
                                .font(.body.weight(.medium))
                            Spacer()
                            Text(Self.readableValue(characteristic))
                                .font(.callout)
                                .foregroundStyle(
                                    characteristic.isKnown ? .primary : .secondary
                                )
                        }
                    }
                }
            }

            if !services.unhandled.isEmpty {
                // Held, not failed. These are on disk and will be read as soon
                // as Hozz learns the shape, so the wording says waiting rather
                // than error — a receiver behind the phone is a temporary
                // state, and describing it as a loss would be wrong twice.
                Section("Waiting to be understood") {
                    ForEach(services.unhandled) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(entry.count) × \(entry.kind)")
                                .font(.body.weight(.medium))
                            Text("Kept safely. A future version of Hozz will read these automatically — nothing needs to be re-sent from your phone.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if services.promotedRecords > 0 {
                Section {
                    Label(
                        "\(services.promotedRecords) records that were waiting have now been read and added.",
                        systemImage: "checkmark.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            // A Mac holding one type is almost always a sweep still working
            // through someone's history, not a broken export. Saying what has
            // arrived, and how far back it reaches, is what stops that being
            // read as "I have no heart data".
            if !services.summaries.isEmpty {
                Section("What has arrived") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(coverageHeadline)
                            .font(.body.weight(.medium))
                        Text(
                            "Your phone sends one type at a time, so anything not listed yet is still queued."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("Measurements") {
                ForEach(services.summaries, id: \.type) { summary in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.readableName(summary.type))
                            .font(.body.weight(.medium))
                        Text("\(summary.recordCount) records")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(summary.type)
                }
            }
        }
        .onChange(of: selected) { _, _ in
            Task { await reload() }
        }
        .onChange(of: bucket) { _, _ in
            Task { await reload() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected, let summary = services.summaries.first(where: { $0.type == selected }) {
            VStack(alignment: .leading, spacing: 16) {
                detailHeader(summary)
                Picker("Group by", selection: $bucket) {
                    ForEach(BucketSize.allCases, id: \.self) { size in
                        Text(size.rawValue.capitalized).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                chart(for: summary)

                // Deliberately without `.fixedSize(horizontal: false, vertical: true)`.
                //
                // That modifier asks this text for its ideal height at the
                // proposed width, and inside a pane that fills the window there
                // is no settled width to answer against yet. The text reported
                // the width it would need to run on one line, the pane resized
                // to that, and the answer changed again — a loop the window
                // never got out of.
                //
                // What it did to the app depended only on how the pane was
                // built. Inside an `HSplitView` AppKit stopped it and killed the
                // process; inside an `HStack` it gives up quietly instead, and
                // the window keeps every frame it had already worked out and
                // draws none of them. That is the empty window: the sidebar,
                // the type list, and this pane were all still there, all the
                // right size, and all invisible.
                //
                // Nothing is lost by removing it. A `Text` given a real width
                // already wraps to as many lines as it needs.
                Text(
                    """
                    Sum and average are both shown because the right one \
                    depends on the measurement: adding up heart rate readings \
                    means nothing, and averaging step counts understates a day.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(24)
        } else {
            ContentUnavailableView(
                "Choose a type",
                systemImage: "sidebar.left",
                description: Text("Pick something on the left to see it over time.")
            )
        }
    }

    private func detailHeader(_ summary: TypeSummary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.readableName(summary.type))
                    .font(.title2.weight(.semibold))
                if let earliest = summary.earliest, let latest = summary.latest {
                    Text(
                        "\(earliest.formatted(date: .abbreviated, time: .omitted)) – \(latest.formatted(date: .abbreviated, time: .omitted))"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Export CSV…") { isExporting = true }
                .fileExporter(
                    isPresented: $isExporting,
                    document: CSVPlaceholder(),
                    contentType: .commaSeparatedText,
                    defaultFilename: summary.type
                ) { result in
                    if case .success(let url) = result {
                        Task {
                            try? await services.exportCSV(type: summary.type, to: url)
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private func chart(for summary: TypeSummary) -> some View {
        if buckets.isEmpty {
            ContentUnavailableView(
                "No values to chart",
                systemImage: "chart.line.downtrend.xyaxis",
                description: Text("This type has records but no numeric values.")
            )
            .frame(height: 260)
        } else {
            Chart(buckets, id: \.start) { point in
                BarMark(
                    x: .value("Date", point.start),
                    y: .value("Total", point.sum)
                )
                .foregroundStyle(.tint)
            }
            .frame(height: 260)
            .chartYAxisLabel(summary.unit ?? "")
        }
    }

    private func reload() async {
        guard let selected else {
            buckets = []
            return
        }
        buckets = await services.aggregate(type: selected, bucket: bucket)
    }

    /// HealthKit identifiers are unreadable in a list; this makes them scannable
    /// without inventing a name that hides which type it really is.
    /// Types received and how far back they reach.
    ///
    /// Deliberately not a fraction of anything: this computer cannot know how
    /// many types the phone intends to send, still less how many records exist,
    /// so a denominator here would be a guess dressed as a measurement.
    private var coverageHeadline: String {
        let count = services.summaries.count
        var text = "\(count) health "
        text += count == 1 ? "type" : "types"
        text += " received"
        if let oldest = services.summaries.compactMap(\.earliest).min() {
            text += ", oldest reaching \(Self.day(oldest))"
        }
        return text + "."
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    /// What to show beside a characteristic's name.
    ///
    /// Health distinguishes "the person has not set this" from "this could not
    /// be read", and both are different from a value. Collapsing them all to a
    /// blank would turn a known fact about the person — that they have not
    /// recorded a blood type — into something indistinguishable from a bug.
    static func readableValue(_ characteristic: StoredCharacteristic) -> String {
        if let value = characteristic.value, characteristic.isKnown {
            return value.replacingOccurrences(
                of: #"([a-z0-9])([A-Z])"#,
                with: "$1 $2",
                options: .regularExpression
            )
        }
        return switch characteristic.state {
        case "notSet": "Not set"
        case "unavailable": "Unavailable"
        case "unrecognised": "Unrecognised value"
        case "unreadable": "Could not be read"
        default: "Unknown"
        }
    }

    static func readableName(_ identifier: String) -> String {
        var name = identifier
        for prefix in [
            "HKQuantityTypeIdentifier",
            "HKCategoryTypeIdentifier",
            "HKCharacteristicTypeIdentifier",
            "HKCorrelationTypeIdentifier"
        ] {
            if name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
                break
            }
        }
        if name == "HKWorkoutTypeIdentifier" {
            return "Workouts"
        }
        var spaced = ""
        for character in name {
            if character.isUppercase, !spaced.isEmpty {
                spaced.append(" ")
            }
            spaced.append(character)
        }
        return spaced.isEmpty ? identifier : spaced
    }
}

/// `fileExporter` needs a document type; the real write happens in the
/// completion handler so the whole export is not held in memory twice.
private struct CSVPlaceholder: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    init() {}
    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}
