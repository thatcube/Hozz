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
            if services.summaries.isEmpty {
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

    private var content: some View {
        HSplitView {
            typeList
                .frame(minWidth: 260, idealWidth: 300)
            detail
                .frame(minWidth: 420)
        }
    }

    private var typeList: some View {
        List(services.summaries, id: \.type, selection: $selected) { summary in
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.readableName(summary.type))
                    .font(.body.weight(.medium))
                Text("\(summary.recordCount) records")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(summary.type)
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

                Text(
                    """
                    Sum and average are both shown because the right one \
                    depends on the measurement: adding up heart rate readings \
                    means nothing, and averaging step counts understates a day.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
