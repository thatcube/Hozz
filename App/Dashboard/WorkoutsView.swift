import Charts
import HealthKit
import HozzUI
import Observation
import SwiftUI

@MainActor
@Observable
final class WorkoutsViewModel {
    private(set) var workouts: [WorkoutSummary] = []
    private(set) var isLoading = false
    private(set) var failure: String?

    private let reader: HealthMetricReader

    init(reader: HealthMetricReader = HealthMetricReader()) {
        self.reader = reader
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // No cap. The summary below adds these up and calls the result a
            // year's total, and the dashboard row that leads here counts them
            // without a cap — so a truncated list made two screens disagree
            // about the same question, one of them confidently wrong by
            // roughly four to one.
            workouts = try await reader.workouts(inLast: 365, limit: HKObjectQueryNoLimit)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Workouts, which carry more than a list row can hold: heart rate range,
/// energy, distance, and for a multi-sport session, each leg on its own terms.
struct WorkoutsView: View {
    @State private var model = WorkoutsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                if let failure = model.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 14))
                        .foregroundStyle(HozzPalette.warning)
                        .hozzCard()
                } else if model.isLoading && model.workouts.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 80)
                } else if model.workouts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No workouts in the last year")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(HozzPalette.inkSoft)
                        Text(
                            "Health does not reveal whether this is empty or unshared."
                        )
                        .hozzCaption()
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .hozzCard()
                } else {
                    summaryCard
                    // Lazy on purpose: a year can hold hundreds of these, and
                    // building every card before the first one appears is a
                    // screen that looks frozen.
                    LazyVStack(spacing: 13) {
                        ForEach(model.workouts) { workout in
                            WorkoutCard(workout: workout)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(HozzSurface())
        .navigationTitle("Workouts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    /// Totals across the year. Duration and energy add up; heart rate does
    /// not, so no average heart rate across every workout is offered — it
    /// would mean nothing and look authoritative.
    private var summaryCard: some View {
        let totalSeconds = model.workouts.reduce(0) { $0 + $1.duration }
        let totalEnergy = model.workouts.compactMap(\.energyKilocalories).reduce(0, +)
        return HStack(spacing: 0) {
            statistic("Workouts", "\(model.workouts.count)")
            divider
            statistic("Time", MetricFormat.duration(totalSeconds))
            divider
            statistic(
                "Energy",
                totalEnergy > 0
                    ? "\(MetricFormat.value(totalEnergy, fractionDigits: 0, abbreviateThousands: true)) kcal"
                    : "—"
            )
        }
        .hozzCard(padding: 15)
    }

    private var divider: some View {
        Rectangle()
            .fill(HozzPalette.lineSoft)
            .frame(width: 1, height: 30)
    }

    private func statistic(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(HozzPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).hozzLabel().textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - One workout

struct WorkoutCard: View {
    let workout: WorkoutSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                HozzIconView(.barbell, size: 16)
                    .foregroundStyle(HozzPalette.blue)
                    .frame(width: 30, height: 30)
                    .background(HozzPalette.blueWash, in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(workout.activityName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(HozzPalette.ink)
                    Text(
                        workout.start.formatted(
                            .dateTime.weekday(.abbreviated).day().month(.abbreviated)
                                .hour().minute()
                        )
                    )
                    .hozzCaption()
                }
                Spacer(minLength: 0)
                Text(MetricFormat.duration(workout.duration))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(HozzPalette.inkSoft)
            }

            figures(
                energy: workout.energyKilocalories,
                distance: workout.distanceMeters,
                average: workout.averageHeartRate,
                minimum: workout.minimumHeartRate,
                maximum: workout.maximumHeartRate
            )

            if workout.isMultiSport {
                legs
            }
        }
        .hozzCard(padding: 15)
    }

    /// Each leg on its own terms.
    ///
    /// An average heart rate across a swim, a ride and a run describes none of
    /// the three, so a multi-sport workout breaks them out rather than
    /// flattening them into one figure.
    private var legs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(HozzPalette.lineSoft)
            Text("Activities")
                .hozzLabel()
                .textCase(.uppercase)
            ForEach(workout.legs) { leg in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(leg.activityName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(HozzPalette.ink)
                        Spacer(minLength: 8)
                        Text(MetricFormat.duration(leg.duration))
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(HozzPalette.inkSoft)
                    }
                    figures(
                        energy: leg.energyKilocalories,
                        distance: leg.distanceMeters,
                        average: leg.averageHeartRate,
                        minimum: leg.minimumHeartRate,
                        maximum: leg.maximumHeartRate,
                        isCompact: true
                    )
                }
                .padding(.leading, 2)
            }
        }
    }

    @ViewBuilder
    private func figures(
        energy: Double?,
        distance: Double?,
        average: Double?,
        minimum: Double?,
        maximum: Double?,
        isCompact: Bool = false
    ) -> some View {
        let items = figureItems(
            energy: energy,
            distance: distance,
            average: average,
            minimum: minimum,
            maximum: maximum
        )
        if !items.isEmpty {
            HStack(spacing: isCompact ? 14 : 18) {
                ForEach(items, id: \.label) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.value)
                            .font(
                                .system(
                                    size: isCompact ? 13 : 15,
                                    weight: .medium,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(HozzPalette.ink)
                        Text(item.label)
                            .font(.system(size: 10, weight: .medium))
                            .tracking(0.6)
                            .foregroundStyle(HozzPalette.inkMuted)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private struct Figure {
        let label: String
        let value: String
    }

    /// Only what this workout actually measured.
    ///
    /// A figure Health did not record is left out rather than shown as a zero.
    /// Nought calories burned on a run is a claim, and an absent measurement
    /// is not that claim.
    private func figureItems(
        energy: Double?,
        distance: Double?,
        average: Double?,
        minimum: Double?,
        maximum: Double?
    ) -> [Figure] {
        var items: [Figure] = []
        if let energy, energy > 0 {
            items.append(
                Figure(
                    label: "KCAL",
                    value: MetricFormat.value(energy, fractionDigits: 0)
                )
            )
        }
        if let distance, distance > 0 {
            items.append(Figure(label: "DISTANCE", value: Self.distanceText(distance)))
        }
        if let average {
            items.append(
                Figure(
                    label: "AVG HR",
                    value: MetricFormat.value(average, fractionDigits: 0)
                )
            )
        }
        if let minimum, let maximum {
            items.append(
                Figure(
                    label: "HR RANGE",
                    value: """
                        \(MetricFormat.value(minimum, fractionDigits: 0))\
                        –\(MetricFormat.value(maximum, fractionDigits: 0))
                        """
                )
            )
        }
        return items
    }

    private static func distanceText(_ metres: Double) -> String {
        if Locale.current.measurementSystem == .us {
            let miles = metres / 1_609.344
            return "\(MetricFormat.value(miles, fractionDigits: 2)) mi"
        }
        let kilometres = metres / 1_000
        return "\(MetricFormat.value(kilometres, fractionDigits: 2)) km"
    }
}
