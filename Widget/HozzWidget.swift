import HozzDeliver
import HozzStore
import SwiftUI
import WidgetKit

/// What the widget shows.
struct SyncEntry: TimelineEntry {
    let date: Date
    let lastSuccessAt: Date?
    let recordCount: Int
    let needsAttention: Bool
    let hasDestination: Bool
    /// True when the widget could not reach the app's data at all.
    ///
    /// A widget runs in its own container, so it can only read the shared store
    /// once the App Groups capability is enabled for this bundle id. Until then
    /// the widget says it cannot see the state, rather than claiming there is
    /// no destination — which would be a confident and wrong answer.
    let isUnavailable: Bool

    static let placeholder = SyncEntry(
        date: .now,
        lastSuccessAt: Date(timeIntervalSinceNow: -1_800),
        recordCount: 128_450,
        needsAttention: false,
        hasDestination: true,
        isUnavailable: false
    )
}

/// Reads delivery state directly from the shared store.
///
/// A widget is also a small nudge to iOS: a home screen timeline gives the
/// system another reason to keep the app scheduled, which is why the common
/// advice for tools like this is "add the widget". Here it is genuinely just a
/// readout — the sync itself is owned by the background task.
struct SyncProvider: TimelineProvider {
    func placeholder(in context: Context) -> SyncEntry {
        .placeholder
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (SyncEntry) -> Void
    ) {
        let box = CompletionBox(completion)
        Task {
            box.call(await Self.currentEntry())
        }
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<SyncEntry>) -> Void
    ) {
        let box = CompletionBox(completion)
        Task {
            box.call(
                Timeline(
                    entries: [await Self.currentEntry()],
                    policy: .after(Date(timeIntervalSinceNow: 30 * 60))
                )
            )
        }
    }

    private static func currentEntry() async -> SyncEntry {
        // The store lives in the shared app group. If it cannot be opened —
        // which on a Lock Screen refresh usually means the device is still
        // locked and the protected file is unreadable — the widget says so
        // rather than claiming there is no destination.
        guard
            let shared = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: StoreLocation.appGroupIdentifier
            ),
            let store = try? HozzStore(
                directory: try StoreLocation.supportDirectory(in: shared)
            ),
            let states = try? await store.allDeliveryStates()
        else {
            return SyncEntry(
                date: .now,
                lastSuccessAt: nil,
                recordCount: 0,
                needsAttention: false,
                hasDestination: false,
                isUnavailable: true
            )
        }

        return SyncEntry(
            date: .now,
            lastSuccessAt: states.compactMap(\.lastSuccessAt).max(),
            recordCount: states.reduce(0) { $0 + $1.deliveredRecords },
            needsAttention: states.contains { $0.state == "needsAttention" },
            hasDestination: !states.isEmpty,
            isUnavailable: false
        )
    }
}

/// Carries WidgetKit's non-Sendable completion handler across an actor hop.
///
/// Each box is called exactly once, from the single task that owns one
/// timeline request, so there is no concurrent access to guard.
private final class CompletionBox<Value>: @unchecked Sendable {
    private let handler: (Value) -> Void

    init(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }

    func call(_ value: Value) {
        handler(value)
    }
}

struct HozzWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SyncEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text("Hozz")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(headline)
                .font(family == .systemSmall ? .subheadline.bold() : .title3.bold())
                .minimumScaleFactor(0.7)
                .lineLimit(2)

            if entry.hasDestination, entry.recordCount > 0 {
                Text("\(entry.recordCount.formatted()) records sent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var headline: String {
        guard !entry.isUnavailable else {
            return "Open Hozz for status"
        }
        guard entry.hasDestination else {
            return "No destination yet"
        }
        if entry.needsAttention {
            return "Needs attention"
        }
        guard let lastSuccessAt = entry.lastSuccessAt else {
            return "Waiting for first sync"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Synced \(formatter.localizedString(for: lastSuccessAt, relativeTo: entry.date))"
    }

    private var symbol: String {
        if entry.isUnavailable { return "questionmark.circle" }
        if !entry.hasDestination { return "tray" }
        if entry.needsAttention { return "exclamationmark.triangle.fill" }
        return entry.lastSuccessAt == nil ? "clock" : "checkmark.icloud.fill"
    }

    private var tint: Color {
        if entry.needsAttention { return .orange }
        return entry.lastSuccessAt == nil ? .secondary : .green
    }
}

struct HozzWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HozzSyncWidget", provider: SyncProvider()) { entry in
            HozzWidgetView(entry: entry)
        }
        .configurationDisplayName("Health Sync")
        .description("When Hozz last sent your Health data, and how much.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct HozzWidgetBundle: WidgetBundle {
    var body: some Widget {
        HozzWidget()
    }
}
