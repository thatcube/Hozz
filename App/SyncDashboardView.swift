import HozzDeliver
import HozzUI
import SwiftUI

/// The home for automatic export.
///
/// Designed against the single biggest failure of tools like this: sync quietly
/// stops and the user finds out weeks later. Every destination states when it
/// last succeeded and what it is doing now, and "Sync now" is always available
/// so nobody has to wonder whether iOS has run the app.
///
/// Drawn as cards on the page wash rather than as a `List`, for the same reason
/// the dashboard is: they are one app and were not reading as one.
struct SyncDashboardView: View {
    @Bindable var model: SyncViewModel
    @State private var editingDestination: Destination?
    @State private var isAddingDestination = false
    @State private var pendingDeletion: Destination?

    var body: some View {
        HozzScreen {
            HozzScreenTitle("Automatic export")

            statusCard

            backfillSection

            if model.hasDestinations {
                HozzSection("Destinations") {
                    ForEach(model.summaries) { summary in
                        Button {
                            editingDestination = summary.destination
                        } label: {
                            DestinationRow(summary: summary)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove", role: .destructive) {
                                pendingDeletion = summary.destination
                            }
                        }
                    }
                }
            }

            HozzSection(footer: destinationFooter) {
                Button {
                    isAddingDestination = true
                } label: {
                    HozzRow(
                        "Add a destination",
                        icon: .folderPlus,
                        isProminent: true
                    ) {
                        HozzChevron()
                    }
                }
                .buttonStyle(.plain)

                if model.hasDestinations {
                    Button {
                        Task { await model.fetchRecentMonthsAgain() }
                    } label: {
                        HozzRow(
                            "Fetch recent months again",
                            icon: .refresh,
                            isProminent: true
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isSyncing)
                    .opacity(model.isSyncing ? 0.5 : 1)
                }
            }

            backgroundRealitySection
        }
        .navigationTitle("Automatic")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.syncNow() }
                } label: {
                    if model.isSyncing {
                        ProgressView()
                    } else {
                        HozzIconView(.refresh, size: 22)
                    }
                }
                .disabled(model.isSyncing || !model.hasDestinations)
                .accessibilityLabel("Sync now")
            }
        }
        .sheet(isPresented: $isAddingDestination) {
            NavigationStack {
                DestinationPickerView(model: model)
            }
        }
        .sheet(item: $editingDestination) { destination in
            NavigationStack {
                DestinationEditorView(model: model, destination: destination)
            }
        }
        // Removing a destination used to be a swipe on a list row, and the list
        // is gone. It is confirmed and named here rather than taken on one
        // gesture, because it is the only thing in Hozz whose removal the app
        // cannot undo.
        .alert(
            "Remove \(pendingDeletion?.name ?? "this destination")?",
            isPresented: .init(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                guard let doomed = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await model.delete(doomed) }
            }
            Button("Keep it", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(
                "Hozz stops sending there. Anything already delivered stays "
                + "where it is."
            )
        }
        .task {
            await model.load()
            await model.startObserving()
        }
        .refreshable {
            await model.load()
        }
    }

    /// What sync is doing right now, said once and prominently.
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                HozzIconWell(statusIcon, tone: statusTone, diameter: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.overallStatus)
                        .hozzHeading(size: 17)
                        .fixedSize(horizontal: false, vertical: true)
                    if let summary = model.lastSyncSummary {
                        Text(summary)
                            .hozzCaption()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            if let error = model.lastError {
                HozzNote(error, icon: .alertTriangle, tone: .warning)
            }
        }
        .hozzCard()
    }

    /// Leads with how many types are *complete*, and carries how many have
    /// started underneath it.
    ///
    /// Completeness is the slow, meaningful number. Because the drain gives
    /// every type a share of each pass, the started count reaches almost
    /// everything within a pass or two and then sits still — shown on its own
    /// it would look like a finished export missing most of the data.
    @ViewBuilder
    private var backfillSection: some View {
        if let backfill = model.backfill, backfill.typesSelected > 0 {
            HozzSection("First sync through your history") {
                VStack(alignment: .leading, spacing: 10) {
                    HozzNote(
                        "\(backfill.typesComplete) of \(backfill.typesSelected) "
                        + "health types complete",
                        icon: backfill.isUnderway ? .refresh : .circleCheck,
                        tone: backfill.isUnderway ? .action : .positive
                    )
                    Text(backfillDetail(backfill))
                        .hozzCaption()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .hozzCard()
            }
        }
    }

    private func backfillDetail(
        _ backfill: SyncViewModel.BackfillProgress
    ) -> String {
        var text = ""
        if backfill.isUnderway {
            // No percentage and no estimate: Health will not say how much a
            // type holds without reading all of it, so both would be invented,
            // and an invented estimate is a promise that gets broken.
            text = "Hozz reads a little of every type each time, so records "
                + "keep arriving long before a type is finished. "
                + "\(backfill.typesStarted) of \(backfill.typesSelected) have "
                + "started. \(backfill.recordsDelivered.formatted()) records "
                + "sent so far."
        } else {
            text = "Every type you selected has been read to the end. "
                + "\(backfill.recordsDelivered.formatted()) records sent so far."
        }
        if backfill.typesEmpty > 0 {
            // An empty type is a complete export of nothing, not a problem.
            text += " \(backfill.typesEmpty) had no data to send."
        }
        if backfill.typesFailed > 0 {
            text += " \(backfill.typesFailed) could not be read."
        }
        return text
    }

    /// States the iOS limits plainly rather than letting the user discover them
    /// as a mystery failure.
    /// Built as statements rather than one expression.
    ///
    /// As a single `Text(...)` with a ternary inside a chain of `+`, this
    /// type-checked fine for the simulator and timed out compiling for a
    /// device — the same source, failing only where it could not be noticed
    /// by running the tests.
    private var destinationFooter: String {
        var text = "A destination is a folder or a web address you control. "
        text += "Hozz has no default and sends nothing until you add one."
        guard model.hasDestinations else { return text }
        text += "\n\nHozz reads the last few months by date as soon as a "
        text += "destination exists, then keeps working backwards through "
        text += "everything older. Fetch them again if you have given Hozz "
        text += "access to more health types since then; anything already "
        text += "sent is simply replaced."
        return text
    }

    private var backgroundRealitySection: some View {
        HozzSection("How background sync behaves") {
            HozzNoteCard {
                HozzNote(
                    "Health can only be read while this iPhone is unlocked.",
                    icon: .lock
                )
                HozzNote(
                    "iOS decides when Hozz runs. Expect within a few hours, "
                    + "not instantly.",
                    icon: .clock
                )
                HozzNote(
                    "Force-quitting Hozz stops it until you open it again.",
                    icon: .alertTriangle
                )
                HozzNote(
                    "Nothing is ever lost. Anything missed is sent on the "
                    + "next run.",
                    icon: .circleCheck
                )
            }
        }
    }

    private var statusIcon: HozzIcon {
        switch model.overallIcon {
        case .healthy: .cloudCheck
        case .retrying: .refresh
        case .attention: .alertTriangle
        case .idle: .cloudUpload
        }
    }

    private var statusTone: HozzTone {
        switch model.overallIcon {
        case .healthy: .positive
        case .retrying, .attention: .warning
        case .idle: .action
        }
    }
}

private struct DestinationRow: View {
    let summary: SyncViewModel.DestinationSummary

    var body: some View {
        HozzRow(
            summary.destination.name,
            detail: detail,
            icon: icon,
            tone: tone
        ) {
            if !summary.destination.isEnabled {
                Text("Off").hozzCaption()
            }
            HozzChevron()
        }
    }

    private var icon: HozzIcon {
        switch summary.state {
        case .delivered: .circleCheck
        case .delivering: .refresh
        case .retrying: .refresh
        case .needsAttention: .alertTriangle
        case .waitingForUnlock: .lock
        case .waitingForSystem: .hourglass
        case .idle: summary.destination.kind == .folder ? .folder : .api
        }
    }

    private var tone: HozzTone {
        switch summary.state {
        case .delivered: .positive
        case .needsAttention, .retrying: .warning
        default: .action
        }
    }

    private var detail: String {
        if let detail = summary.detail, !summary.state.isHealthy {
            return detail
        }
        if let success = summary.lastSuccessAt {
            let records = summary.deliveredRecords.formatted()
            return "\(records) records · \(SyncViewModel.relative(success))"
        }
        if !summary.destination.isConfigured {
            return "Setup not finished"
        }
        return "Waiting for the first sync"
    }
}
