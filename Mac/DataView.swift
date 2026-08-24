import Charts
import SwiftUI
import HozzUI
import HozzReceive
import UniformTypeIdentifiers

/// Which dashboard is on screen.
enum DataSection: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case types = "Types"
    case compare = "Compare"
    case workouts = "Workouts"
    case heart = "ECG"
    case mood = "Mood"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .types: "list.bullet"
        case .compare: "chart.xyaxis.line"
        case .workouts: "figure.run"
        case .heart: "waveform.path.ecg"
        case .mood: "brain.head.profile"
        }
    }
}

/// The archive, as dashboards rather than as a table with a histogram.
struct DataView: View {
    let services: MacServices
    @State private var section: DataSection = .overview
    @State private var selectedType: String?
    @State private var isExporting = false

    var body: some View {
        Group {
            if services.summaries.isEmpty && services.characteristics.isEmpty {
                ContentUnavailableView {
                    Label("Nothing received yet", systemImage: "tray")
                } description: {
                    Text("Once your phone syncs, everything it sends appears here.")
                }
            } else {
                VStack(spacing: 0) {
                    sectionBar
                    Divider().overlay(HozzPalette.lineSoft)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Data")
        .task { await services.refresh() }
    }

    /// A tab strip rather than a toolbar item.
    ///
    /// The window's toolbar belongs to the outer split view, and putting a
    /// segmented control there made the detail pane's width depend on the
    /// toolbar's — the same negotiation that has already killed this window
    /// once. Kept inside the pane, it asks nothing of anything above it.
    private var sectionBar: some View {
        HStack(spacing: 4) {
            ForEach(DataSection.allCases) { option in
                Button {
                    section = option
                } label: {
                    Label(option.rawValue, systemImage: option.symbol)
                        .font(.callout.weight(section == option ? .semibold : .regular))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(section == option ? HozzPalette.blueWash : Color.clear)
                        .foregroundStyle(
                            section == option ? HozzPalette.ink : HozzPalette.inkSoft
                        )
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if section == .types, let selectedType {
                Button("Export CSV…") { isExporting = true }
                    .buttonStyle(.link)
                    .fileExporter(
                        isPresented: $isExporting,
                        document: CSVPlaceholder(),
                        contentType: .commaSeparatedText,
                        defaultFilename: selectedType
                    ) { result in
                        if case .success(let url) = result {
                            Task {
                                try? await services.exportCSV(
                                    type: selectedType,
                                    to: url
                                )
                            }
                        }
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    /// One range for every dashboard, owned by the services object so the
    /// screens agree and so it can be chosen from what the archive holds.
    private var rangeBinding: Binding<ChartRange> {
        Binding(
            get: { services.range },
            set: { services.range = $0 }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .overview:
            OverviewView(
                services: services,
                selectedType: $selectedType,
                section: $section,
                range: rangeBinding
            )
        case .types:
            typesPane
        case .compare:
            CompareView(services: services, range: rangeBinding)
        case .workouts:
            WorkoutsView(services: services)
        case .heart:
            ElectrocardiogramView(services: services)
        case .mood:
            MoodView(services: services)
        }
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
    private var typesPane: some View {
        HStack(spacing: 0) {
            typeList
                .frame(width: 290)
            Divider().overlay(HozzPalette.lineSoft)
            typeDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var typeList: some View {
        List(selection: $selectedType) {
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

            Section("Measurements") {
                ForEach(services.summaries, id: \.type) { summary in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.readableName(summary.type, unit: summary.unit))
                            .font(.body.weight(.medium))
                        Text("\(summary.recordCount.formatted(.number)) records")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(summary.type)
                }
            }
        }
    }

    @ViewBuilder
    private var typeDetail: some View {
        if let selectedType {
            TypeDetailView(
                services: services,
                type: selectedType,
                range: rangeBinding
            )
        } else {
            ContentUnavailableView(
                "Choose a type",
                systemImage: "sidebar.left",
                description: Text("Pick something on the left to see it over time.")
            )
        }
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

    /// HealthKit identifiers are unreadable in a list; this makes them scannable
    /// without inventing a name that hides which type it really is.
    static func readableName(_ identifier: String, unit: String? = nil) -> String {
        HealthMeasure.measure(for: identifier, storedUnit: unit).displayName
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
