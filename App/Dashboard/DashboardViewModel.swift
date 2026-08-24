import Foundation
import HealthKit
import HozzHealth
import Observation

/// What the overview knows, and how honestly it says it.
///
/// Loading is per metric rather than all-or-nothing. One type failing — a
/// version of iOS that does not have it, a read that errors — must not blank
/// the whole screen, and the card for that one says what happened while the
/// rest carry on.
@MainActor
@Observable
final class DashboardViewModel {
    enum Access: Equatable {
        /// Health is not on this device at all.
        case unavailable
        /// Hozz has never put the permission sheet in front of this person.
        case notAsked
        /// The sheet has been shown. Whether any particular type was allowed
        /// is deliberately not knowable — a declined type reads as empty.
        case asked
    }

    private(set) var access: Access = .notAsked
    private(set) var cards: [MetricCardState] = []
    private(set) var isLoading = false
    private(set) var isRequestingAccess = false
    private(set) var failure: String?
    private(set) var workoutCount: Int?
    private(set) var electrocardiogramCount: Int?

    private let reader: HealthMetricReader
    private let metrics: [DashboardMetric]

    init(
        reader: HealthMetricReader = HealthMetricReader(),
        metrics: [DashboardMetric] = DashboardMetrics.headline
    ) {
        self.reader = reader
        self.metrics = metrics
        self.cards = metrics.map { MetricCardState(metric: $0, series: nil, failure: nil) }
    }

    func refresh() async {
        guard await reader.isAvailable else {
            access = .unavailable
            return
        }
        access = await reader.hasBeenAsked(for: DashboardMetrics.all) ? .asked : .notAsked
        guard access == .asked else {
            return
        }
        await load()
    }

    /// Asks for Health access, for the types the dashboard actually draws.
    ///
    /// Deliberately narrower than the export's request. Someone opening the
    /// app to look at their step count should not be asked for everything
    /// Health holds as the price of it; the export asks for its own wider set
    /// when they set one up.
    func requestAccess() async {
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        do {
            try await reader.requestAccess(to: DashboardMetrics.all)
            access = .asked
            await load()
        } catch {
            failure = error.localizedDescription
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        failure = nil

        let reader = reader
        let metrics = metrics
        let loaded = await withTaskGroup(
            of: (Int, Result<MetricSeries, any Error>).self
        ) { group in
            for (index, metric) in metrics.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await reader.series(for: metric, range: .week)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results: [Int: Result<MetricSeries, any Error>] = [:]
            for await (index, result) in group {
                results[index] = result
            }
            return results
        }

        cards = metrics.enumerated().map { index, metric in
            switch loaded[index] {
            case .success(let series):
                MetricCardState(metric: metric, series: series, failure: nil)
            case .failure(let error):
                MetricCardState(
                    metric: metric,
                    series: nil,
                    failure: error.localizedDescription
                )
            case nil:
                MetricCardState(metric: metric, series: nil, failure: nil)
            }
        }

        async let workouts = try? await reader.workoutCount(inLast: 365)
        async let electrocardiograms = try? await reader.electrocardiogramCount()
        workoutCount = await workouts
        electrocardiogramCount = await electrocardiograms
    }
}

/// One card on the overview.
struct MetricCardState: Identifiable, Sendable {
    let metric: DashboardMetric
    let series: MetricSeries?
    let failure: String?

    var id: String { metric.id }

    /// The most recent bucket that holds anything.
    ///
    /// The overview leads with this rather than with "today" unconditionally,
    /// because a card that says nothing whenever today happens to be empty is
    /// a card that is blank most mornings. Saying *when* the figure is from is
    /// what keeps that honest.
    var latest: MetricBucket? {
        series?.buckets.last { $0.hasData }
    }

    var summary: MetricSummary? {
        series?.summary
    }

    var hasAnyData: Bool {
        series?.hasAnyData ?? false
    }
}
