import HozzDeliver
import HozzUI
import SwiftUI

/// The home for automatic export.
///
/// Designed against the single biggest failure of tools like this: sync quietly
/// stops and the user finds out weeks later. Every destination states when it
/// last succeeded and what it is doing now, and "Sync now" is always available
/// so nobody has to wonder whether iOS has run the app.
struct SyncDashboardView: View {
    @Bindable var model: SyncViewModel
    @State private var editingDestination: Destination?
    @State private var isAddingDestination = false

    var body: some View {
        List {
            statusSection
            backfillSection

            if model.hasDestinations {
                Section("Destinations") {
                    ForEach(model.summaries) { summary in
                        Button {
                            editingDestination = summary.destination
                        } label: {
                            DestinationRow(summary: summary)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indexSet in
                        let doomed = indexSet.map { model.summaries[$0].destination }
                        Task {
                            for destination in doomed {
                                await model.delete(destination)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    isAddingDestination = true
                } label: {
                    HozzLabel("Add a destination", icon: .folderPlus)
                }
            } footer: {
                Text(
                    "A destination is a folder or a web address you control. "
                    + "Hozz has no default and sends nothing until you add one."
                )
            }

            backgroundRealitySection
        }
        .navigationTitle("Automatic export")
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
        .task {
            await model.load()
            await model.startObserving()
        }
        .refreshable {
            await model.load()
        }
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
            Section("First sync through your history") {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            "\(backfill.typesComplete) of \(backfill.typesSelected) health types complete"
                        )
                        .font(.body.weight(.medium))

                        Text(backfillDetail(backfill))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(
                        systemName: backfill.isUnderway
                            ? "arrow.triangle.2.circlepath"
                            : "checkmark.circle"
                    )
                    .foregroundStyle(
                        backfill.isUnderway ? HozzPalette.action : .green
                    )
                }
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

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                HozzIconView(statusIcon, size: 30)
                    .foregroundStyle(statusColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.overallStatus)
                        .font(.headline)
                    if let summary = model.lastSyncSummary {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 6)

            if let error = model.lastError {
                HozzLabel(.alertTriangle) {
                    Text(error).font(.footnote)
                }
                .foregroundStyle(.orange)
            }
        }
    }

    /// States the iOS limits plainly rather than letting the user discover them
    /// as a mystery failure.
    private var backgroundRealitySection: some View {
        Section("How background sync behaves") {
            HozzLabel(.lock) {
                Text("Health can only be read while this iPhone is unlocked.")
            }
            HozzLabel(.clock) {
                Text("iOS decides when Hozz runs. Expect within a few hours, not instantly.")
            }
            HozzLabel(.alertTriangle) {
                Text("Force-quitting Hozz stops it until you open it again.")
            }
            HozzLabel(.circleCheck) {
                Text("Nothing is ever lost. Anything missed is sent on the next run.")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var statusIcon: HozzIcon {
        switch model.overallIcon {
        case .healthy: .cloudCheck
        case .retrying: .refresh
        case .attention: .alertTriangle
        case .idle: .cloudUpload
        }
    }

    private var statusColor: Color {
        switch model.overallIcon {
        case .healthy: .green
        case .retrying: .orange
        case .attention: .orange
        case .idle: HozzPalette.action
        }
    }
}

private struct DestinationRow: View {
    let summary: SyncViewModel.DestinationSummary

    var body: some View {
        HStack(spacing: 12) {
            HozzIconView(icon, size: 24)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.destination.name)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !summary.destination.isEnabled {
                Text("Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HozzIconView(.chevronRight, size: 16)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
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

    private var kindIcon: HozzIcon {
        switch summary.destination.kind {
        case .folder: .folder
        case .restAPI: .api
        case .mqtt: .plugConnected
        }
    }

    private var color: Color {
        switch summary.state {
        case .delivered: .green
        case .needsAttention, .retrying: .orange
        default: .secondary
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
