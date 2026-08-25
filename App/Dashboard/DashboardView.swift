import HozzUI
import SwiftUI

/// The screen Hozz opens on: what this person's own body has been doing,
/// drawn from Health on the device and sent nowhere.
struct DashboardView: View {
    @State private var model = DashboardViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                content
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .background(HozzSurface())
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Health changes while the app is away — a walk, a night's sleep —
            // and coming back to yesterday's numbers makes the app look stale
            // when it is only unrefreshed.
            guard phase == .active, model.access == .asked else {
                return
            }
            Task { await model.load() }
        }
        .refreshable { await model.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .hozzLabel()
                .textCase(.uppercase)
            Text("Your health")
                .hozzDisplay(size: 30)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch model.access {
        case .unavailable:
            unavailableCard
        case .notAsked:
            invitationCard
        case .asked:
            loadedContent
        }
    }

    private var unavailableCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HozzIconView(.alertTriangle, size: 22)
                .foregroundStyle(HozzPalette.inkSoft)
            Text("Apple Health is unavailable here")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(HozzPalette.ink)
            Text(
                """
                This device does not provide Health data, so there is nothing \
                for Hozz to chart. Exporting still works from a device that does.
                """
            )
            .hozzCaption()
            .fixedSize(horizontal: false, vertical: true)
        }
        .hozzCard()
    }

    /// Nothing is read until this is tapped.
    ///
    /// Hozz does not put a permission sheet in front of someone the instant
    /// they open it. The app says what it wants and why first, and the sheet
    /// only follows a deliberate tap — the same principle that keeps it from
    /// picking a destination on anyone's behalf.
    private var invitationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HozzIconView(.chartLine, size: 26)
                .foregroundStyle(HozzPalette.blue)
            Text("See your own data")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(HozzPalette.ink)
            Text(
                """
                Hozz can chart what Apple Health already holds — steps, sleep, \
                heart rate, workouts. It is read on this device, drawn on this \
                device, and sent nowhere.
                """
            )
            .font(.system(size: 14))
            .foregroundStyle(HozzPalette.inkSoft)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await model.requestAccess() }
            } label: {
                HStack(spacing: 8) {
                    if model.isRequestingAccess {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.isRequestingAccess ? "Asking Health…" : "Show my health data")
                        .font(.system(size: 15, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            .tint(HozzPalette.blue)
            .disabled(model.isRequestingAccess)
            .padding(.top, 2)

            if let failure = model.failure {
                Text(failure)
                    .hozzCaption()
                    .foregroundStyle(HozzPalette.warning)
            }
        }
        .hozzCard(padding: 22)
    }

    @ViewBuilder
    private var loadedContent: some View {
        if model.isLoading && model.cards.allSatisfy({ $0.series == nil }) {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading Health…").hozzCaption()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: HozzMetrics.gridGap),
                    GridItem(.flexible(), spacing: HozzMetrics.gridGap)
                ],
                spacing: HozzMetrics.gridGap
            ) {
                ForEach(model.cards) { card in
                    NavigationLink {
                        MetricDetailView(metric: card.metric)
                    } label: {
                        MetricCardView(card: card)
                    }
                    .buttonStyle(.plain)
                }
            }

            collections

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
    }

    @ViewBuilder
    private var collections: some View {
        VStack(spacing: 10) {
            NavigationLink {
                WorkoutsView()
            } label: {
                CollectionRow(
                    icon: .barbell,
                    title: "Workouts",
                    detail: model.workoutCount.map { count in
                        count == 0
                            ? "None in the last year"
                            : "\(count.formatted()) in the last year"
                    }
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                ElectrocardiogramListView()
            } label: {
                CollectionRow(
                    icon: .activity,
                    title: "Electrocardiograms",
                    detail: model.electrocardiogramCount.map { count in
                        count == 0 ? "None recorded" : "\(count.formatted()) recorded"
                    }
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                MetricBrowseView()
            } label: {
                CollectionRow(
                    icon: .chartDots,
                    title: "Everything else",
                    detail: "\(DashboardMetrics.browsable.count) more types"
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }
}

// MARK: - A card

struct MetricCardView: View {
    let card: MetricCardState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                HozzIconView(card.metric.icon, size: 13)
                    .foregroundStyle(HozzPalette.blue)
                Text(card.metric.title)
                    .hozzLabel()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }

            content
        }
        .frame(height: 132, alignment: .topLeading)
        .hozzCard(padding: 14, radius: 18)
    }

    @ViewBuilder
    private var content: some View {
        if let failure = card.failure {
            Text(failure)
                .hozzCaption()
                .lineLimit(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let series = card.series, let latest = card.latest, let value = latest.value {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(MetricFormat.headline(value, for: card.metric))
                        .hozzDisplay(size: 27)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if !isSleep {
                        Text(card.metric.unitLabel)
                            .hozzUnit()
                            .lineLimit(1)
                    }
                }
                Text(whenLabel(for: latest))
                    .hozzCaption()
            }
            Spacer(minLength: 0)
            MetricSparkline(series: series)
        } else if card.series != nil {
            MetricEmptyNote(isCompact: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // Still reading. A skeleton rather than a spinner per card, which
            // would make the grid flicker.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(HozzPalette.skeleton)
                .frame(height: 26)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 30)
        }
    }

    private var isSleep: Bool {
        if case .sleep = card.metric.kind { return true }
        return false
    }

    /// Says when the figure is from, so a card showing Friday's number on a
    /// Sunday cannot be mistaken for today's.
    private func whenLabel(for bucket: MetricBucket) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(bucket.interval.start) {
            return "Today"
        }
        if calendar.isDateInYesterday(bucket.interval.start) {
            return "Yesterday"
        }
        return bucket.interval.start.formatted(.dateTime.weekday(.wide))
    }
}

// MARK: - A row leading somewhere

struct CollectionRow: View {
    let icon: HozzIcon
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 12) {
            HozzIconView(icon, size: 17)
                .foregroundStyle(HozzPalette.blue)
                .frame(width: 30, height: 30)
                .background(HozzPalette.blueWash, in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(HozzPalette.ink)
                if let detail {
                    Text(detail).hozzCaption()
                }
            }
            Spacer(minLength: 0)
            HozzIconView(.chevronRight, size: 14)
                .foregroundStyle(HozzPalette.inkMuted)
        }
        .hozzCard(padding: 13, radius: 16)
    }
}

// MARK: - Browsing the rest

struct MetricBrowseView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(DashboardMetrics.browsable) { metric in
                    NavigationLink {
                        MetricDetailView(metric: metric)
                    } label: {
                        CollectionRow(
                            icon: metric.icon,
                            title: metric.title,
                            detail: metric.unitLabel
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(HozzSurface())
        .navigationTitle("All types")
        .navigationBarTitleDisplayMode(.inline)
    }
}
