import Charts
import MapKit
import SwiftUI
import HozzUI
import HozzReceive

/// Every workout, and one workout properly.
struct WorkoutsView: View {
    let services: MacServices
    @State private var selected: IngestStore.StoredWorkout?

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 300)
            Divider().overlay(HozzPalette.lineSoft)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await services.loadWorkouts() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(services.workouts, id: \.id) { workout in
                    Button {
                        selected = workout
                    } label: {
                        row(workout)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(HozzPalette.lineSoft)
                }
            }
        }
        .background(HozzPalette.air.opacity(0.4))
    }

    private func row(_ workout: IngestStore.StoredWorkout) -> some View {
        let chosen = selected?.id == workout.id
        return HStack(spacing: 10) {
            Image(systemName: WorkoutActivity.symbol(workout.activityType))
                .font(.body)
                .frame(width: 22)
                .foregroundStyle(HozzPalette.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(WorkoutActivity.name(workout.activityType))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(HozzPalette.ink)
                Text(workout.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(HozzPalette.inkMuted)
            }
            Spacer()
            Text(WorkoutFormat.duration(workout.duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(HozzPalette.inkSoft)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(chosen ? HozzPalette.blueWash : Color.clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var detail: some View {
        if let selected {
            WorkoutDetailView(services: services, workout: selected)
        } else if services.workouts.isEmpty {
            ContentUnavailableView(
                "No workouts yet",
                systemImage: "figure.run",
                description: Text("They appear here as your phone sends them.")
            )
        } else {
            ContentUnavailableView(
                "Choose a workout",
                systemImage: "figure.run",
                description: Text(
                    "\(services.workouts.count) held, "
                        + "the most recent from "
                        + (services.workouts.first?.startDate.formatted(
                            date: .abbreviated,
                            time: .omitted
                        ) ?? "—")
                        + "."
                )
            )
        }
    }
}

/// One workout: what Health computed about it, its route, and its legs.
struct WorkoutDetailView: View {
    let services: MacServices
    let workout: IngestStore.StoredWorkout
    @State private var route: WorkoutRoute?
    @State private var heartRate: [HeartRatePoint] = []
    @State private var isLoaded = false

    struct HeartRatePoint: Identifiable, Equatable {
        let at: Date
        let beatsPerMinute: Double
        var id: Date { at }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Dash.gutter) {
                header
                statsCard
                if let route, !route.isEmpty {
                    routeCard(route)
                }
                if heartRate.count > 1 {
                    heartRateCard
                }
                if !workout.activities.isEmpty {
                    legsCard
                }
                allStatisticsCard
            }
            .dashboardPage()
        }
        .task(id: workout.id) {
            isLoaded = false
            route = await services.route(forWorkout: workout.id)
            heartRate = await services.heartRate(duringWorkout: workout.id)
                .map { HeartRatePoint(at: $0.at, beatsPerMinute: $0.beatsPerMinute) }
            isLoaded = true
        }
    }

    /// The path, drawn only as far as it is actually known.
    private func routeCard(_ route: WorkoutRoute) -> some View {
        Card(
            title: "Route",
            subtitle: route.isComplete
                ? "\(route.points.count.formatted(.number)) locations recorded."
                : "\(route.points.count.formatted(.number)) locations recorded, "
                    + "with \(route.missingPages) "
                    + (route.missingPages == 1 ? "gap" : "gaps")
                    + " where pages have not arrived. The line is drawn through what is held."
        ) {
            Map(initialPosition: .region(Self.region(for: route))) {
                MapPolyline(coordinates: route.points.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .stroke(HozzPalette.blue, lineWidth: 3)

                if let first = route.points.first {
                    Annotation("Start", coordinate: CLLocationCoordinate2D(
                        latitude: first.latitude,
                        longitude: first.longitude
                    )) {
                        Circle()
                            .fill(HozzPalette.blue)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    }
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if !route.isComplete {
                // Said plainly rather than left to the map. A straight line
                // across a gap looks exactly like a road.
                Label(
                    "Straight segments may be missing pages rather than the way somebody went.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(HozzPalette.inkMuted)
            }
        }
    }

    /// A region that holds the whole path with a little air around it.
    private static func region(for route: WorkoutRoute) -> MKCoordinateRegion {
        let latitudes = route.points.map(\.latitude)
        let longitudes = route.points.map(\.longitude)
        guard
            let minLatitude = latitudes.min(), let maxLatitude = latitudes.max(),
            let minLongitude = longitudes.min(), let maxLongitude = longitudes.max()
        else {
            return MKCoordinateRegion()
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * 1.35, 0.004),
                longitudeDelta: max((maxLongitude - minLongitude) * 1.35, 0.004)
            )
        )
    }

    private var heartRateCard: some View {
        Card(
            title: "Heart rate through the session",
            subtitle: "\(heartRate.count.formatted(.number)) readings, in beats per minute."
        ) {
            Chart(heartRate) { point in
                LineMark(
                    x: .value("When", point.at),
                    y: .value("bpm", point.beatsPerMinute)
                )
                .foregroundStyle(HozzPalette.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .interpolationMethod(.monotone)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(HozzPalette.lineSoft)
                    AxisValueLabel().foregroundStyle(HozzPalette.inkMuted)
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(HozzPalette.lineSoft.opacity(0.6))
                    AxisValueLabel().foregroundStyle(HozzPalette.inkMuted)
                }
            }
            .frame(height: 180)
        }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(WorkoutActivity.name(workout.activityType))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(HozzPalette.ink)
                Text(
                    workout.startDate.formatted(date: .complete, time: .shortened)
                        + (workout.sourceName.map { " · \($0)" } ?? "")
                )
                .font(.callout)
                .foregroundStyle(HozzPalette.inkSoft)
            }
            Spacer()
        }
    }

    private var statsCard: some View {
        Card {
            HStack(spacing: 0) {
                StatTile(
                    label: "Duration",
                    value: WorkoutFormat.duration(workout.duration)
                )
                if let energy = statistic("HKQuantityTypeIdentifierActiveEnergyBurned") {
                    StatTile(
                        label: "Active energy",
                        value: WorkoutFormat.value(energy.sum, of: energy),
                        unit: WorkoutFormat.label(energy.sum, of: energy)
                    )
                }
                if let distance = totalDistance {
                    StatTile(
                        label: distanceLabel,
                        value: distance.unit.format(distance.metres),
                        unit: distance.unit.label
                    )
                }
                if let heart = statistic("HKQuantityTypeIdentifierHeartRate") {
                    StatTile(
                        label: "Heart rate",
                        value: WorkoutFormat.value(heart.average, of: heart),
                        unit: WorkoutFormat.label(heart.average, of: heart),
                        caption: heartRangeCaption(heart)
                    )
                }
            }
        }
    }

    /// The low and high the watch actually recorded.
    ///
    /// Converted rather than printed: Health stores a pulse in `count/s`, so a
    /// minimum of 0.88 is not a heart rate anybody recognises.
    private func heartRangeCaption(
        _ statistic: IngestStore.StoredWorkoutStatistic
    ) -> String? {
        guard let low = statistic.minimum, let high = statistic.maximum else {
            return nil
        }
        let unit = WorkoutFormat.unit(for: statistic, magnitude: high)
        return "\(unit.format(low))–\(unit.format(high)) range"
    }

    /// Every distance in this workout added together.
    ///
    /// A triathlon's parent workout carries `DistanceSwimming`,
    /// `DistanceCycling` and `DistanceWalkingRunning` as three separate rows.
    /// Taking the first of them — which, ordered by type, is the bike — put
    /// "Distance 42.20 km" at the top of a workout that covered 51.5, two cards
    /// above a Legs section whose whole subtitle is that a figure standing for
    /// one leg describes none of them.
    ///
    /// They are all cumulative and all in metres, so a sum is the real total.
    private var totalDistance: (metres: Double, unit: DisplayUnit)? {
        let parts = workout.statistics.filter {
            $0.type.contains("Distance") && $0.unit == "m"
        }
        let metres = parts.compactMap(\.sum).reduce(0, +)
        guard !parts.isEmpty, metres > 0 else {
            return nil
        }
        let measure = HealthMeasure.measure(
            for: parts[0].type,
            storedUnit: "m"
        )
        return (metres, measure.displayUnit(forMagnitude: metres))
    }

    /// Named for what it actually is, so a combined figure is never read as
    /// one discipline's.
    private var distanceLabel: String {
        let kinds = Set(
            workout.statistics
                .filter { $0.type.contains("Distance") && $0.unit == "m" }
                .map(\.type)
        )
        return kinds.count > 1 ? "Distance (all legs)" : "Distance"
    }

    private var legsCard: some View {
        Card(
            title: "Legs",
            subtitle: "Each part on its own, because an average across a swim, a ride and a run describes none of them."
        ) {
            VStack(spacing: 0) {
                ForEach(Array(workout.activities.enumerated()), id: \.offset) { index, leg in
                    if index > 0 {
                        Divider().overlay(HozzPalette.lineSoft)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: WorkoutActivity.symbol(leg.activityType))
                            .frame(width: 20)
                            .foregroundStyle(HozzPalette.series(index))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(WorkoutActivity.name(leg.activityType))
                                .font(.callout.weight(.medium))
                                .foregroundStyle(HozzPalette.ink)
                            Text(leg.startDate.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(HozzPalette.inkMuted)
                        }
                        Spacer()
                        Text(legSummary(leg))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(HozzPalette.inkSoft)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func legSummary(_ leg: IngestStore.StoredWorkoutActivity) -> String {
        let parts = leg.statistics.prefix(3).map { statistic in
            WorkoutFormat.short(statistic)
        }
        return parts.isEmpty ? "no statistics" : parts.joined(separator: " · ")
    }

    private var allStatisticsCard: some View {
        Card(
            title: "Everything Health computed",
            subtitle: "\(workout.statistics.count) statistics, exactly as they arrived."
        ) {
            if workout.statistics.isEmpty {
                Text("None recorded for this workout.")
                    .font(.callout)
                    .foregroundStyle(HozzPalette.inkMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(workout.statistics.enumerated()), id: \.offset) { index, statistic in
                        if index > 0 {
                            Divider().overlay(HozzPalette.lineSoft)
                        }
                        HStack {
                            Text(HealthMeasure.measure(
                                for: statistic.type,
                                storedUnit: statistic.unit
                            ).displayName)
                            .font(.callout)
                            .foregroundStyle(HozzPalette.inkSoft)
                            Spacer()
                            Text(WorkoutFormat.full(statistic))
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(HozzPalette.ink)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private func statistic(_ type: String) -> IngestStore.StoredWorkoutStatistic? {
        workout.statistics.first { $0.type == type }
    }

}

/// Naming and drawing a workout by its HealthKit activity number.
enum WorkoutActivity {
    /// The activities that actually turn up, named as people name them.
    ///
    /// Deliberately partial. An unknown number is reported as an unknown
    /// number rather than guessed at, because a walk labelled "Yoga" is worse
    /// than a walk labelled "Activity 52".
    private static let names: [Int: (String, String)] = [
        13: ("Cycling", "figure.outdoor.cycle"),
        16: ("Elliptical", "figure.elliptical"),
        24: ("Hiking", "figure.hiking"),
        35: ("Functional strength", "figure.strengthtraining.functional"),
        37: ("Running", "figure.run"),
        44: ("Stairs", "figure.stairs"),
        46: ("Swimming", "figure.pool.swim"),
        52: ("Walking", "figure.walk"),
        57: ("Yoga", "figure.yoga"),
        63: ("Mind & body", "figure.mind.and.body"),
        70: ("Pilates", "figure.pilates"),
        3000: ("Other", "figure.mixed.cardio"),
        20: ("Core training", "figure.core.training"),
        50: ("Traditional strength", "figure.strengthtraining.traditional"),
        59: ("High intensity interval", "figure.highintensity.intervaltraining"),
        79: ("Cooldown", "figure.cooldown")
    ]

    static func name(_ activityType: Int?) -> String {
        guard let activityType else { return "Workout" }
        return names[activityType]?.0 ?? "Activity \(activityType)"
    }

    static func symbol(_ activityType: Int?) -> String {
        guard let activityType else { return "figure.mixed.cardio" }
        return names[activityType]?.1 ?? "figure.mixed.cardio"
    }
}

/// Formatting for workout statistics, which arrive in Health's own units.
///
/// Everything about a value's unit is deferred to ``HealthMeasure``, which is
/// the app's one table of what a type is stored in and how it should be read.
/// An earlier version of this file kept a second, smaller table keyed on the
/// unit string alone, and it was wrong in exactly the ways a duplicate table
/// gets wrong: `m` is the canonical unit of running stride length and
/// underwater depth as well as of nine distance types, so a 1.14 m stride
/// printed as `0.00 km`; and `count/s` is the canonical unit of respiratory
/// rate as well as heart rate, so a breathing rate was labelled `bpm`.
enum WorkoutFormat {
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m \(total % 60)s"
    }

    /// How this statistic's type should be read.
    static func unit(
        for statistic: IngestStore.StoredWorkoutStatistic,
        magnitude: Double
    ) -> DisplayUnit {
        HealthMeasure
            .measure(for: statistic.type, storedUnit: statistic.unit)
            .displayUnit(forMagnitude: magnitude)
    }

    /// A statistic's own value, with the unit it is actually in.
    static func value(
        _ value: Double?,
        of statistic: IngestStore.StoredWorkoutStatistic
    ) -> String {
        guard let value else { return "—" }
        return unit(for: statistic, magnitude: value).format(value)
    }

    static func label(
        _ value: Double?,
        of statistic: IngestStore.StoredWorkoutStatistic
    ) -> String {
        unit(for: statistic, magnitude: value ?? 0).label
    }

    /// The statistic Health actually computed, whichever it is.
    ///
    /// A sum and an average are different facts, so whichever the row carries
    /// is what gets shown — never one relabelled as the other.
    static func full(_ statistic: IngestStore.StoredWorkoutStatistic) -> String {
        if let sum = statistic.sum {
            return unit(for: statistic, magnitude: sum).formatted(sum)
        }
        guard let average = statistic.average else {
            return "—"
        }
        let display = unit(for: statistic, magnitude: average)
        var text = "avg \(display.formatted(average))"
        if let low = statistic.minimum, let high = statistic.maximum {
            text += " (\(display.format(low))–\(display.format(high)))"
        }
        return text
    }

    /// The same, short enough for a leg's summary line.
    ///
    /// Carries its unit. Without one a 1,200 m swim leg read "Distance 1.20"
    /// beside a run leg reading "Distance 5.00", with nothing on screen to say
    /// that the first had been divided by a thousand and the second had not.
    static func short(_ statistic: IngestStore.StoredWorkoutStatistic) -> String {
        let measure = HealthMeasure.measure(
            for: statistic.type,
            storedUnit: statistic.unit
        )
        let name = measure.displayName
            .split(separator: " ")
            .first
            .map(String.init) ?? measure.displayName
        guard let value = statistic.sum ?? statistic.average else {
            return name
        }
        let display = measure.displayUnit(forMagnitude: value)
        return "\(name) \(display.formatted(value))"
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespaces)
    }
}
