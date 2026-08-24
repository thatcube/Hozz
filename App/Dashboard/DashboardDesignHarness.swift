#if DEBUG
import HozzUI
import SwiftUI

/// A way to look at the dashboard without a device.
///
/// The simulator has no Health data and there is no way to put any there —
/// `simctl privacy` has no health service, and the permission sheet cannot be
/// tapped from a script. So the screens would otherwise only ever be seen on
/// Brandon's phone, and "it builds" would have to stand in for "it looks
/// right", which it does not.
///
/// This feeds made-up series into the *real* views, charts, formatting and
/// palette. It proves the drawing, not the reading: the reading is proved by
/// running the app against Health itself. Both are needed, because each hides
/// what the other shows.
///
/// Compiled out of release builds entirely, and reachable in a debug build
/// only by launching with `-HozzDesignHarness`.
enum DashboardHarnessLaunch {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-HozzDesignHarness")
    }

    /// Which screen to open on, so a screenshot can be taken of any of them
    /// without a tap. The simulator cannot be tapped from a script, and every
    /// screen needs looking at.
    static var tab: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard
            let index = arguments.firstIndex(of: "-HozzHarnessTab"),
            index + 1 < arguments.count,
            let value = Int(arguments[index + 1])
        else {
            return 0
        }
        return value
    }
}

enum SampleSeries {
    private static var calendar: Calendar { .current }

    private static func intervals(_ range: MetricRange) -> [DateInterval] {
        MetricBucketing.buckets(for: range, endingAt: .now, calendar: calendar)
    }

    /// A series with a value in every bucket.
    static func full(
        _ range: MetricRange,
        aggregation: MetricAggregation,
        base: Double,
        spread: Double,
        unit: String,
        overall: Double? = nil
    ) -> MetricSeries {
        make(
            range,
            aggregation: aggregation,
            base: base,
            spread: spread,
            unit: unit,
            filled: intervals(range).count,
            overall: overall
        )
    }

    /// The shape that made this whole design necessary: a range whose data
    /// only begins part way through, because history is still arriving.
    static func partial(
        _ range: MetricRange,
        aggregation: MetricAggregation,
        base: Double,
        spread: Double,
        unit: String,
        filled: Int,
        overall: Double? = nil
    ) -> MetricSeries {
        make(
            range,
            aggregation: aggregation,
            base: base,
            spread: spread,
            unit: unit,
            filled: filled,
            overall: overall
        )
    }

    static func empty(_ range: MetricRange, aggregation: MetricAggregation) -> MetricSeries {
        MetricAggregator.aggregate([], into: intervals(range), using: aggregation)
    }

    private static func make(
        _ range: MetricRange,
        aggregation: MetricAggregation,
        base: Double,
        spread: Double,
        unit: String,
        filled: Int,
        overall: Double?
    ) -> MetricSeries {
        let all = intervals(range)
        // Deterministic, so a screenshot taken twice is the same screenshot.
        var seed = 20_260_824
        func next() -> Double {
            seed = (seed &* 1_103_515_245 &+ 12_345) & 0x7FFF_FFFF
            return Double(seed % 1_000) / 1_000
        }

        let buckets = all.enumerated().map { index, interval -> MetricBucket in
            guard index >= all.count - filled else {
                return MetricBucket(
                    interval: interval,
                    value: nil,
                    minimum: nil,
                    maximum: nil,
                    readingCount: 0,
                    sampleCount: 0
                )
            }
            let wobble = (next() - 0.5) * 2 * spread
            let value = max(0, base + wobble)
            return MetricBucket(
                interval: interval,
                value: value,
                minimum: max(0, value - spread * 0.6),
                maximum: value + spread * 0.6,
                readingCount: 0,
                sampleCount: 1
            )
        }

        return MetricSeries(
            buckets: buckets,
            unit: unit,
            aggregation: aggregation,
            hasUnitConflict: false,
            containsAggregatedReadings: aggregation == .average,
            overall: overall.map {
                MetricOverall(value: $0, minimum: $0 - spread, maximum: $0 + spread * 2.4)
            }
        )
    }

    static let steps = DashboardMetrics.headline[0]
    static let energy = DashboardMetrics.headline[1]
    static let restingHeartRate = DashboardMetrics.headline[2]
    static let sleep = DashboardMetrics.headline[3]
    static let distance = DashboardMetrics.headline[4]
    static let exercise = DashboardMetrics.headline[5]

    /// The overview's six cards, deliberately mixed: two of them show the
    /// awkward states rather than a screen of tidy ones.
    static var cards: [MetricCardState] {
        [
            MetricCardState(
                metric: steps,
                series: full(.week, aggregation: .total, base: 9_400, spread: 3_800, unit: "count"),
                failure: nil
            ),
            MetricCardState(
                metric: energy,
                series: full(.week, aggregation: .total, base: 620, spread: 240, unit: "kcal"),
                failure: nil
            ),
            MetricCardState(
                metric: restingHeartRate,
                series: full(
                    .week,
                    aggregation: .average,
                    base: 56,
                    spread: 5,
                    unit: "count/min",
                    overall: 56.4
                ),
                failure: nil
            ),
            MetricCardState(
                metric: sleep,
                series: partial(
                    .week,
                    aggregation: .total,
                    base: 7.1,
                    spread: 1.3,
                    unit: "hr",
                    filled: 4
                ),
                failure: nil
            ),
            MetricCardState(
                metric: distance,
                series: full(.week, aggregation: .total, base: 6.2, spread: 2.6, unit: "km"),
                failure: nil
            ),
            MetricCardState(
                metric: exercise,
                series: empty(.week, aggregation: .total),
                failure: nil
            )
        ]
    }
}

/// The harness itself: the real overview chrome, then the states worth
/// looking at side by side.
struct DashboardDesignHarness: View {
    @State private var selection = DashboardHarnessLaunch.tab

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { overview }
                .tabItem { Label("Overview", systemImage: "square.grid.2x2") }
                .tag(0)
            NavigationStack { detail }
                .tabItem { Label("Detail", systemImage: "chart.xyaxis.line") }
                .tag(1)
            NavigationStack { states }
                .tabItem { Label("States", systemImage: "list.bullet") }
                .tag(2)
            NavigationStack { workouts }
                .tabItem { Label("Workouts", systemImage: "figure.run") }
                .tag(3)
        }
        .tint(HozzPalette.action)
    }

    /// Workouts, including a multi-sport one, which is the layout most likely
    /// to break and the least likely to be seen by accident.
    private var workouts: some View {
        let now = Date.now
        let single = WorkoutSummary(
            id: UUID(),
            activityName: "Running",
            start: now.addingTimeInterval(-9_000),
            end: now.addingTimeInterval(-6_300),
            duration: 2_700,
            energyKilocalories: 412,
            distanceMeters: 7_240,
            averageHeartRate: 148,
            minimumHeartRate: 96,
            maximumHeartRate: 176,
            legs: []
        )
        let triathlon = WorkoutSummary(
            id: UUID(),
            activityName: "Triathlon",
            start: now.addingTimeInterval(-180_000),
            end: now.addingTimeInterval(-170_000),
            duration: 10_000,
            energyKilocalories: 1_180,
            // Nothing, on purpose: a workout that measured three kinds of
            // distance has no single one, and the legs below carry them.
            distanceMeters: nil,
            averageHeartRate: 141,
            minimumHeartRate: 88,
            maximumHeartRate: 179,
            legs: [
                WorkoutLeg(
                    id: UUID(),
                    activityName: "Swimming",
                    start: now.addingTimeInterval(-180_000),
                    end: now.addingTimeInterval(-178_200),
                    duration: 1_800,
                    energyKilocalories: 210,
                    distanceMeters: 1_500,
                    averageHeartRate: 132,
                    minimumHeartRate: 88,
                    maximumHeartRate: 150
                ),
                WorkoutLeg(
                    id: UUID(),
                    activityName: "Cycling",
                    start: now.addingTimeInterval(-178_200),
                    end: now.addingTimeInterval(-173_000),
                    duration: 5_200,
                    energyKilocalories: 640,
                    distanceMeters: 38_000,
                    averageHeartRate: 138,
                    minimumHeartRate: 104,
                    maximumHeartRate: 168
                ),
                WorkoutLeg(
                    id: UUID(),
                    activityName: "Running",
                    start: now.addingTimeInterval(-173_000),
                    end: now.addingTimeInterval(-170_000),
                    duration: 3_000,
                    energyKilocalories: 330,
                    distanceMeters: 2_100,
                    averageHeartRate: 159,
                    minimumHeartRate: 128,
                    maximumHeartRate: 179
                )
            ]
        )
        return ScrollView {
            VStack(spacing: 13) {
                WorkoutCard(workout: triathlon)
                WorkoutCard(workout: single)
                ECGRow(
                    reading: ECGSummary(
                        id: UUID(),
                        recordedAt: now.addingTimeInterval(-86_400),
                        classification: "Sinus rhythm",
                        symptoms: "No symptoms reported",
                        averageHeartRate: 62,
                        samplingFrequencyHertz: 512,
                        expectedMeasurementCount: 15_360,
                        duration: 30
                    )
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(HozzSurface())
        .navigationTitle("Workouts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                        .hozzLabel()
                        .textCase(.uppercase)
                    Text("Your health").hozzDisplay(size: 30)
                }
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 13),
                        GridItem(.flexible(), spacing: 13)
                    ],
                    spacing: 13
                ) {
                    ForEach(SampleSeries.cards) { card in
                        MetricCardView(card: card)
                    }
                }

                VStack(spacing: 10) {
                    CollectionRow(
                        icon: .barbell,
                        title: "Workouts",
                        detail: "812 in the last year"
                    )
                    CollectionRow(
                        icon: .activity,
                        title: "Electrocardiograms",
                        detail: "13 recorded"
                    )
                    CollectionRow(
                        icon: .chartDots,
                        title: "Everything else",
                        detail: "10 more types"
                    )
                }
                .padding(.top, 4)

                Text(
                    """
                    Read from Apple Health on this device. Hozz sends nothing \
                    anywhere until you add a destination yourself.
                    """
                )
                .hozzCaption()
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .background(HozzSurface())
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A month whose data begins only eleven days in — Brandon's actual shape.
    private var detail: some View {
        let series = SampleSeries.partial(
            .month,
            aggregation: .total,
            base: 9_100,
            spread: 3_600,
            unit: "count",
            filled: 11
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Picker("Range", selection: .constant(MetricRange.month)) {
                    ForEach(MetricRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total, 30 days").hozzLabel().textCase(.uppercase)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(
                                MetricFormat.headline(
                                    series.summary.headline ?? 0,
                                    for: SampleSeries.steps
                                )
                            )
                            .hozzDisplay(size: 36)
                            Text("steps").hozzUnit()
                        }
                    }
                    MetricChart(series: series, metric: SampleSeries.steps, range: .month)
                    MetricCoverageNote(coverage: series.coverage(now: .now), range: .month)
                }
                .hozzCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Resting heart rate, a year").hozzLabel().textCase(.uppercase)
                    MetricChart(
                        series: SampleSeries.full(
                            .year,
                            aggregation: .average,
                            base: 57,
                            spread: 4,
                            unit: "count/min",
                            overall: 56.8
                        ),
                        metric: SampleSeries.restingHeartRate,
                        range: .year
                    )
                }
                .hozzCard()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(HozzSurface())
        .navigationTitle("Steps")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The states that are easy to get wrong because they are rarely seen.
    private var states: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Nothing in range").hozzLabel().textCase(.uppercase)
                    MetricEmptyNote()
                }
                .hozzCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("One day only").hozzLabel().textCase(.uppercase)
                    MetricChart(
                        series: SampleSeries.partial(
                            .week,
                            aggregation: .total,
                            base: 8_200,
                            spread: 0,
                            unit: "count",
                            filled: 1
                        ),
                        metric: SampleSeries.steps,
                        range: .week,
                        height: 150
                    )
                    MetricCoverageNote(
                        coverage: SampleSeries.partial(
                            .week,
                            aggregation: .total,
                            base: 8_200,
                            spread: 0,
                            unit: "count",
                            filled: 1
                        ).coverage(now: .now),
                        range: .week
                    )
                }
                .hozzCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("An incomplete trace").hozzLabel().textCase(.uppercase)
                    Label("This trace is incomplete", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.orange)
                    Text(
                        """
                        4,096 of 15,360 readings arrived. What is drawn below is \
                        part of the recording, not the whole of it.
                        """
                    )
                    .hozzCaption()
                    .fixedSize(horizontal: false, vertical: true)
                    ECGWaveformChart(envelope: Self.sampleWaveform, isComplete: false)
                }
                .hozzCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("A whole trace").hozzLabel().textCase(.uppercase)
                    ECGWaveformChart(envelope: Self.sampleWaveform, isComplete: true)
                    Text("Lead I equivalent, in microvolts.").hozzCaption()
                }
                .hozzCard()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(HozzSurface())
        .navigationTitle("States")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A plausible trace: a slow baseline with a QRS spike every second,
    /// pushed through the real decimation so the drawing is the real drawing.
    private static var sampleWaveform: [ECGEnvelope] {
        let hertz = 512.0
        let points = (0..<Int(hertz * 12)).map { index -> ECGPoint in
            let seconds = Double(index) / hertz
            let phase = seconds.truncatingRemainder(dividingBy: 0.95)
            var microvolts = 18 * sin(seconds * 2.4)
            if phase < 0.012 {
                microvolts += 620 * sin(phase / 0.012 * .pi)
            } else if phase < 0.05 {
                microvolts -= 130 * sin((phase - 0.012) / 0.038 * .pi)
            } else if phase > 0.2, phase < 0.34 {
                microvolts += 70 * sin((phase - 0.2) / 0.14 * .pi)
            }
            return ECGPoint(secondsSinceStart: seconds, microvolts: microvolts)
        }
        return ECGDecimation.envelope(points, buckets: 360)
    }
}
#endif
