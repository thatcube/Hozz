import Foundation
import HozzCore
import HozzDeliver
import HozzHealth
import HozzStore
import Observation
import SwiftUI

/// Drives the sync dashboard and destination editing.
///
/// The single most common complaint about tools in this space is that
/// background sync stops and nobody notices. Everything here exists to make
/// that impossible: every destination shows when it last succeeded, what state
/// it is in right now, and why — and a manual sync is always one tap away.
@MainActor
@Observable
final class SyncViewModel {
    struct DestinationSummary: Identifiable {
        let destination: Destination
        let state: DeliveryState
        let lastSuccessAt: Date?
        let lastAttemptAt: Date?
        let nextAttemptAt: Date?
        let deliveredRecords: Int
        let detail: String?

        var id: UUID { destination.id }
    }

    private(set) var summaries: [DestinationSummary] = []
    private(set) var isSyncing = false
    private(set) var lastError: String?
    private(set) var lastSyncSummary: String?
    private(set) var isObserving = false
    private(set) var backfill: BackfillProgress?

    /// How far the first sweep through someone's history has got.
    ///
    /// A full history is drained a bounded batch at a time, type by type, so a
    /// phone with years of data spends its early passes on whichever types come
    /// first and has genuinely not looked at the rest yet. Someone seeing one
    /// type arrive concludes the export is broken, or that they have no heart
    /// data. Neither is true, and saying which types have been reached is the
    /// difference between a working sync that looks broken and one that
    /// explains itself.
    ///
    /// Deliberately no percentage. HealthKit will not say how many records a
    /// type holds without reading all of them, so any fraction would be
    /// invented — and a progress bar is a promise about time remaining, which
    /// is the one thing that genuinely cannot be known here.
    struct BackfillProgress: Equatable {
        /// Types every destination that wants them has read to the end.
        ///
        /// This is the number that means something. A type is complete only
        /// when Health returned an empty page for it — the one piece of
        /// evidence that there is nothing more to send — and only when every
        /// destination that wants it has got that far.
        let typesComplete: Int
        /// Types Hozz has read at least once.
        ///
        /// Kept alongside `typesComplete` rather than instead of it. The drain
        /// gives every type a share of each pass, so this climbs to almost
        /// everything within a pass or two and then stops moving while the
        /// real work continues. Shown on its own it would read as a finished
        /// export that is inexplicably missing most of the data.
        let typesStarted: Int
        /// Types this phone is set up to send.
        let typesSelected: Int
        let recordsDelivered: Int
        /// Types Health answered for but had nothing in. Not a failure: an
        /// empty type is a complete export of nothing.
        let typesEmpty: Int
        let typesFailed: Int

        var isUnderway: Bool {
            typesSelected > 0 && typesComplete < typesSelected
        }
    }

    @ObservationIgnored private var services: HozzServices?

    var hasDestinations: Bool { !summaries.isEmpty }

    /// The single honest sentence shown at the top of the dashboard.
    var overallStatus: String {
        guard hasDestinations else {
            return "No destination yet. Nothing leaves this iPhone."
        }
        if isSyncing {
            return "Syncing now…"
        }
        if summaries.contains(where: { $0.state == .needsAttention }) {
            return "A destination needs your attention."
        }
        if summaries.contains(where: { $0.state == .retrying }) {
            return "Retrying a destination that could not be reached."
        }
        guard let latest = summaries.compactMap(\.lastSuccessAt).max() else {
            return "Waiting for the first sync."
        }
        return "Last synced \(Self.relative(latest))."
    }

    var overallIcon: HozzStatusIcon {
        if summaries.contains(where: { $0.state == .needsAttention }) {
            return .attention
        }
        if summaries.contains(where: { $0.state == .retrying }) {
            return .retrying
        }
        return summaries.contains(where: { $0.lastSuccessAt != nil })
            ? .healthy
            : .idle
    }

    func load() async {
        do {
            let services = try await resolveServices()
            let destinations = try await services.delivery.destinations()
            var built: [DestinationSummary] = []

            for destination in destinations {
                let state = try await services.delivery.state(for: destination.id)
                // A destination Hozz only half understands has never been
                // delivered to, whatever the stored state says, so it is shown
                // as needing attention rather than as idle or delivered.
                let unsupported = destination.unsupportedDescription
                built.append(
                    DestinationSummary(
                        destination: destination,
                        state: unsupported != nil
                            ? .needsAttention
                            : state.flatMap { DeliveryState(rawValue: $0.state) } ?? .idle,
                        lastSuccessAt: state?.lastSuccessAt,
                        lastAttemptAt: state?.lastAttemptAt,
                        nextAttemptAt: state?.nextAttemptAt,
                        deliveredRecords: state?.deliveredRecords ?? 0,
                        detail: unsupported ?? state?.detail
                    )
                )
            }
            summaries = built
            backfill = try await Self.backfillProgress(
                services: services,
                destinations: destinations
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Counts how far the sweep has reached, from state the store already
    /// holds.
    ///
    /// A type counts as *reached* once a cursor has been committed for it,
    /// which is exactly what "Hozz has drained some of this type" means.
    ///
    /// A type counts as complete only when Health returned an empty page for
    /// it, which is the one piece of evidence that there is nothing more to
    /// send, and only when every destination that wants it has got that far.
    /// A type the budget cut short commits as `draining` with no closure time
    /// and is counted as started instead.
    private static func backfillProgress(
        services: HozzServices,
        destinations: [Destination]
    ) async throws -> BackfillProgress? {
        var gathered: [(destination: Destination, streams: [StreamRecord])] = []
        for destination in destinations {
            gathered.append(
                (
                    destination,
                    try await services.store.streamRecords(
                        scope: .destination(destination.id)
                    )
                )
            )
        }
        return backfillProgress(
            gathered: gathered,
            everything: Set(services.syncTypes)
        )
    }

    /// Counts the backfill from what the store holds.
    ///
    /// Kept pure and separate from the fetching so a test can drive it with
    /// real stream records rather than reimplementing the arithmetic, which
    /// would only prove the copy agrees with itself.
    nonisolated static func backfillProgress(
        gathered: [(destination: Destination, streams: [StreamRecord])],
        everything: Set<HealthTypeKey>
    ) -> BackfillProgress? {
        // A destination that names no types means every type Hozz drains, so
        // that is the denominator for it. Counting the whole catalogue would
        // be wrong — most of it is never read — and counting nothing at all,
        // which is what this used to do, hid the display from everyone who had
        // not narrowed their selection.
        let selected = gathered.reduce(into: Set<HealthTypeKey>()) {
            $0.formUnion(
                $1.destination.includedTypes.isEmpty
                    ? everything
                    : $1.destination.includedTypes
            )
        }
        guard !selected.isEmpty else {
            return nil
        }

        var started: Set<HealthTypeKey> = []
        var incomplete: Set<HealthTypeKey> = []
        var closed: Set<HealthTypeKey> = []
        var withRecords: Set<HealthTypeKey> = []
        var failed: Set<HealthTypeKey> = []
        var wanted: Set<HealthTypeKey> = []
        var records = 0

        for (destination, streams) in gathered {
            let byType = Dictionary(
                streams.map { ($0.type, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            for type in selected where destination.includes(type) {
                wanted.insert(type)
                guard let stream = byType[type] else {
                    // This destination has never reached the type, so it
                    // cannot be complete however far the others have got.
                    incomplete.insert(type)
                    continue
                }
                records += stream.recordCount
                if stream.recordCount > 0 {
                    withRecords.insert(type)
                    started.insert(type)
                }
                if stream.anchorClosedAt != nil {
                    closed.insert(type)
                    started.insert(type)
                } else {
                    // Committed but still draining: read, not finished.
                    incomplete.insert(type)
                }
                if stream.failureReason != nil {
                    failed.insert(type)
                }
            }
        }

        // Complete means every destination that wants it reached the end. One
        // destination still owed data is data still owed.
        let complete = closed.subtracting(incomplete)
        failed.subtract(complete)

        return BackfillProgress(
            typesComplete: complete.count,
            typesStarted: started.count,
            typesSelected: wanted.count,
            recordsDelivered: records,
            typesEmpty: complete.subtracting(withRecords).count,
            typesFailed: failed.count
        )
    }

    func save(_ destination: Destination, secret: String?) async {
        do {
            let services = try await resolveServices()
            try await services.delivery.save(destination)
            if let secret {
                try await services.delivery.setSecret(secret, for: destination)
            }
            await load()
            await restartObserving()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ destination: Destination) async {
        do {
            let services = try await resolveServices()
            try await services.delivery.delete(id: destination.id)
            await load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Runs a sync immediately, regardless of cadence.
    ///
    /// This is the answer to "is it working?" — the user never has to wait on
    /// iOS to find out.
    func syncNow() async {
        guard !isSyncing else {
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let services = try await resolveServices()
            try await services.exporter.requestAuthorization()
            let outcome = try await services.sync.sync(force: true)
            lastSyncSummary = Self.describe(outcome)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await load()
    }

    /// Sends a tiny probe so the user sees a real response before trusting a
    /// destination. The most common setup failure in this space is a wrong auth
    /// header discovered days later.
    func test(_ destination: Destination, secret: String?) async -> String {
        do {
            let services = try await resolveServices()
            if let secret {
                try await services.delivery.setSecret(secret, for: destination)
            }
            return try await services.delivery.test(destination)
        } catch {
            return error.localizedDescription
        }
    }

    func startObserving() async {
        do {
            let services = try await resolveServices()
            await services.startObserving()
            isObserving = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func restartObserving() async {
        guard isObserving else {
            return
        }
        await startObserving()
    }

    private func resolveServices() async throws -> HozzServices {
        if let services {
            return services
        }
        let services = try HozzServices()
        self.services = services
        return services
    }

    private static func describe(_ outcome: SyncOutcome) -> String {
        if outcome.waitingForUnlock {
            return "Waiting for this iPhone to be unlocked."
        }
        if outcome.deliveredRecords == 0 {
            return "Everything was already up to date."
        }
        let plural = outcome.deliveredRecords == 1 ? "record" : "records"
        return "Sent \(outcome.deliveredRecords.formatted()) \(plural)."
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

enum HozzStatusIcon {
    case healthy
    case retrying
    case attention
    case idle
}
