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
                built.append(
                    DestinationSummary(
                        destination: destination,
                        state: state.flatMap { DeliveryState(rawValue: $0.state) } ?? .idle,
                        lastSuccessAt: state?.lastSuccessAt,
                        lastAttemptAt: state?.lastAttemptAt,
                        nextAttemptAt: state?.nextAttemptAt,
                        deliveredRecords: state?.deliveredRecords ?? 0,
                        detail: state?.detail
                    )
                )
            }
            summaries = built
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
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
