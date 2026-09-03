import HozzHealth
import HozzUI
import SwiftUI

/// Every screen the Export tab can be showing.
///
/// Lifted out of `RootView` when they were restyled, because the tab structure
/// and six full screens in one file is how the export flow came to be drawn in
/// a language nothing else in the app used: it was never next to anything to
/// compare it against.

// MARK: - Before an export

struct ExportSetupView: View {
    let healthDataAvailable: Bool
    let isRequestingAccess: Bool
    let exportFormat: HealthExportFormat
    let resumable: ExportViewModel.ResumableSummary?
    let selectExportFormat: (HealthExportFormat) -> Void
    let exportAction: () -> Void
    let discardAction: () -> Void

    var body: some View {
        HozzScreen {
            introduction

            if !healthDataAvailable {
                HozzNoteCard {
                    HozzNote(
                        "Apple Health is unavailable on this device.",
                        icon: .alertTriangle,
                        tone: .warning
                    )
                }
            }

            if let resumable {
                unfinishedSection(resumable)
            }

            formatSection

            HozzSection("Current coverage") {
                HozzNoteCard {
                    CoverageRow("Quantity and category samples", available: true)
                    CoverageRow("Basic workout records", available: true)
                    CoverageRow("Workout routes", available: true)
                    CoverageRow("Electrocardiograms", available: true)
                    CoverageRow("Audiograms", available: true)
                    CoverageRow("State of Mind", available: true)
                    CoverageRow("Medication doses", available: true)
                    CoverageRow("Health characteristics", available: true)
                    CoverageRow("Historical deletions", available: true)
                    // Driven by the build rather than written down, so it stays
                    // true whichever build someone is holding.
                    CoverageRow(
                        "Health records",
                        available: ClinicalRecordsSupport.isBuiltIn
                    )
                    CoverageRow("Correlations and documents", available: false)
                }
            }

            HozzSection {
                Link(destination: HozzLinks.source) {
                    HozzRow("Source code", icon: .github, isProminent: true)
                }
                Link(destination: HozzLinks.sponsors) {
                    HozzRow(
                        "Support development",
                        icon: .heartHandshake,
                        isProminent: true
                    )
                }
                Link(destination: HozzLinks.developer) {
                    HozzRow("More apps", icon: .world, isProminent: true)
                }
            }
        }
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button(action: exportAction) {
                HStack(spacing: 9) {
                    if isRequestingAccess {
                        ProgressView().controlSize(.small)
                    } else {
                        HozzIconView(.download, size: 18)
                    }
                    Text(buttonTitle)
                }
            }
            .buttonStyle(.hozzFilled)
            .disabled(!healthDataAvailable || isRequestingAccess)
            .padding(.horizontal, HozzMetrics.gutter)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.bar)
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            HozzIconView(.download, size: 30)
                .foregroundStyle(HozzPalette.blue)
            Text("Export Apple Health")
                .hozzDisplay(size: 28)
            Text(
                "Choose Health access and save a file on this device."
            )
            .hozzBody()
            .fixedSize(horizontal: false, vertical: true)
        }
        .hozzCard(padding: 22)
    }

    private func unfinishedSection(
        _ resumable: ExportViewModel.ResumableSummary
    ) -> some View {
        HozzSection("Unfinished export") {
            HozzNoteCard {
                if let obstruction = resumable.obstruction {
                    // Shown rather than hidden. An unfinished export that
                    // disappears with nothing said is worse than one that
                    // explains why it is stuck.
                    HozzNote(obstruction, icon: .alertTriangle, tone: .warning)
                } else {
                    HozzNote(
                        "\(resumable.recordCount.formatted()) records saved. Continue from there.",
                        icon: .refresh
                    )
                }
            }

            Button("Discard unfinished export", role: .destructive, action: discardAction)
                .buttonStyle(.hozzQuiet(tone: .warning))
        }
    }

    private var formatSection: some View {
        HozzSection("Format", footer: formatFooter) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Save as")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(HozzPalette.ink)
                    Spacer(minLength: 12)
                    Picker(
                        "Format",
                        selection: Binding(
                            get: { exportFormat },
                            set: { selectExportFormat($0) }
                        )
                    ) {
                        Text("NDJSON").tag(HealthExportFormat.ndjson)
                        Text("CSV").tag(HealthExportFormat.csv)
                        Text("JSON").tag(HealthExportFormat.json)
                        Text("SQLite").tag(HealthExportFormat.sqlite)
                        Text("Markdown").tag(HealthExportFormat.markdown)
                        Text("GPX").tag(HealthExportFormat.gpx)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(HozzPalette.blue)
                    // The unfinished run dictates the format only while it can
                    // actually be continued.
                    .disabled(resumable?.canContinue == true)
                }

                HozzNote(formatNote, icon: formatIcon)

                if exportFormat.coversRoutesOnly {
                    // Not a footnote. Someone picking this expecting a health
                    // export gets an archive that looks broken, and finding
                    // that out afterwards is the whole problem.
                    HozzNote(
                        "GPX exports workout routes only. Choose NDJSON or SQLite for all data.",
                        icon: .alertTriangle,
                        tone: .warning
                    )
                }

                if resumable?.canContinue == true {
                    // Changing format now would throw away everything the
                    // unfinished run has already sealed, so the choice belongs
                    // to that run until it finishes or is discarded.
                    HozzNote(
                        "The unfinished export uses this format. Discard it to change.",
                        icon: .lock
                    )
                }
            }
            .hozzCard()
        }
    }

    private var formatFooter: String? { nil }

    private var formatNote: String {
        switch exportFormat {
        case .ndjson:
            "One record per line; preserves all Health fields."
        case .csv:
            "One spreadsheet per type; omits metadata and workout details."
        case .json:
            "One readable array; slower for large exports."
        case .sqlite:
            "A queryable database preserving every record."
        case .markdown:
            "Daily Obsidian notes; omits records behind totals."
        case .gpx:
            "One GPX track per workout route."
        case .raw:
            "Uncompressed; may be several gigabytes."
        }
    }

    private var formatIcon: HozzIcon {
        switch exportFormat {
        case .ndjson: .listCheck
        case .csv: .fileCSV
        case .json: .code
        case .sqlite: .database
        case .markdown: .calendar
        case .gpx: .world
        case .raw: .fileText
        }
    }

    private var buttonTitle: String {
        if isRequestingAccess {
            return "Waiting for Health access"
        }
        guard let resumable else {
            return "Export now"
        }
        // A run that cannot be continued starts a fresh one instead, so the
        // button says what will actually happen.
        return resumable.canContinue ? "Continue export" : "Export now"
    }
}

/// One line of what Hozz can and cannot export yet.
struct CoverageRow: View {
    let title: String
    let available: Bool

    init(_ title: String, available: Bool) {
        self.title = title
        self.available = available
    }

    var body: some View {
        HozzNote(
            title,
            icon: available ? .circleCheck : .hourglass,
            tone: available ? .positive : .neutral
        )
        .opacity(available ? 1 : 0.72)
    }
}

// MARK: - While an export runs

struct ExportSessionView: View {
    let presentation: ExportViewModel.ProgressPresentation
    let exportFormat: HealthExportFormat
    let pauseAction: () -> Void

    var body: some View {
        ExportStepList(presentation: presentation)
            .background(HozzSurface())
            .safeAreaInset(edge: .top) {
                // Stays pinned, as it was when it sat above a `List` in a
                // `VStack`. It is the one thing on this screen someone is
                // actually watching, and the steps below it scroll themselves
                // as the export advances.
                ExportSessionHeader(
                    presentation: presentation,
                    exportFormat: exportFormat
                )
                .padding(.horizontal, HozzMetrics.gutter)
                .padding(.bottom, 10)
                .background(.bar)
            }
            .navigationTitle("Exporting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Pause", role: .cancel, action: pauseAction)
                        .tint(HozzPalette.blue)
                }
            }
            .safeAreaInset(edge: .bottom) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ExportSessionSummary(
                        presentation: presentation,
                        now: context.date
                    )
                }
            }
    }
}

private struct ExportSessionHeader: View {
    let presentation: ExportViewModel.ProgressPresentation
    let exportFormat: HealthExportFormat

    var body: some View {
        let progress = presentation.export

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(progress.completedTypes.formatted())
                    .hozzDisplay(size: 28)
                Text("of \(progress.totalTypes) data types")
                    .hozzUnit()
                Spacer(minLength: 0)
                HozzLabel(formatIcon, size: 15) {
                    Text(exportFormat.displayName).hozzCaption()
                }
                .foregroundStyle(HozzPalette.inkMuted)
            }

            ProgressView(
                value: Double(progress.completedTypes),
                total: Double(max(progress.totalTypes, 1))
            )
            .tint(HozzPalette.blue)
        }
    }

    private var formatIcon: HozzIcon {
        exportFormat == .raw ? .fileText : .download
    }
}

private struct ExportStepList: View {
    let presentation: ExportViewModel.ProgressPresentation
    @State private var showsEmptyTypes = false

    private var steps: [ExportViewModel.ExportStep] { presentation.steps }

    private var emptySteps: [ExportViewModel.ExportStep] {
        steps.filter { $0.state == .indeterminate }
    }

    private var visibleSteps: [ExportViewModel.ExportStep] {
        showsEmptyTypes ? steps : steps.filter { $0.state != .indeterminate }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy, and one clock for the whole list.
                //
                // The catalog holds 212 types, so a long export is the normal
                // case rather than an edge one — and tapping "Show" on the
                // empty types materialises all of them at once. A plain
                // `VStack` built every row up front, and a `TimelineView` per
                // row gave each of them its own timer firing every second, all
                // while this same screen is reading HealthKit and writing the
                // export. Only the one running row uses the elapsed figure.
                LazyVStack(alignment: .leading, spacing: HozzMetrics.sectionGap) {
                    if !emptySteps.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showsEmptyTypes.toggle()
                            }
                        } label: {
                            HozzRow(
                                "\(emptySteps.count) types with no data",
                                icon: .filter,
                                isProminent: true
                            ) {
                                Text(showsEmptyTypes ? "Hide" : "Show")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(HozzPalette.blue)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = max(
                            context.date.timeIntervalSince(
                                presentation.currentTypeStartedAt
                            ),
                            0
                        )
                        HozzSection("Data types") {
                            ForEach(visibleSteps) { step in
                                ExportStepRow(step: step, currentTypeElapsed: elapsed)
                                    .id(step.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, HozzMetrics.gutter)
                .padding(.top, HozzMetrics.screenTop)
                .padding(.bottom, HozzMetrics.screenBottom)
            }
            .onAppear {
                scrollToCurrent(using: proxy, animated: false)
            }
            .onChange(of: visibleSteps.last?.id) {
                scrollToCurrent(using: proxy, animated: true)
            }
        }
    }

    private func scrollToCurrent(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let id = visibleSteps.last?.id else {
            return
        }

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

private struct ExportStepRow: View {
    let step: ExportViewModel.ExportStep
    let currentTypeElapsed: TimeInterval

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.name)
                    .font(
                        .system(
                            size: 15,
                            weight: step.state == .exporting ? .semibold : .medium
                        )
                    )
                    .foregroundStyle(HozzPalette.ink)
                Text(detail).hozzCaption()
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hozzCard(padding: HozzMetrics.rowPadding, radius: HozzMetrics.rowRadius)
        .overlay(
            RoundedRectangle(
                cornerRadius: HozzMetrics.rowRadius,
                style: .continuous
            )
            .strokeBorder(
                step.state == .exporting ? HozzPalette.blue : .clear,
                lineWidth: 1.5
            )
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.state {
        case .exporting:
            ProgressView().controlSize(.small)
        case .completed:
            HozzIconWell(.circleCheck, tone: .positive)
        case .indeterminate:
            // Finishing with nothing is a normal, successful outcome for most
            // people on most types, so it reads as done rather than as a
            // problem. The caveat that Apple will not say whether a type was
            // unshared or simply empty is stated once, in the summary.
            HozzIconView(.check, size: 17)
                .foregroundStyle(HozzPalette.inkMuted)
                .frame(width: 30, height: 30)
        case .failed:
            HozzIconWell(.alertTriangle, tone: .warning)
        }
    }

    private var detail: String {
        switch step.state {
        case .exporting:
            "\(step.recordCount.formatted()) records · "
                + durationLabel(currentTypeElapsed)
        case .completed:
            "\(step.recordCount.formatted()) records"
        case .indeterminate:
            "No records"
        case .failed:
            "Could not finish this data type"
        }
    }
}

private struct ExportSessionSummary: View {
    let presentation: ExportViewModel.ProgressPresentation
    let now: Date

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 22) {
                recordMetric
                elapsedMetric
                if let estimate = remainingEstimate {
                    SummaryMetric(
                        value: etaLabel(estimate),
                        label: "Estimated left"
                    )
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                recordMetric
                elapsedMetric

                if let estimate = remainingEstimate {
                    SummaryMetric(
                        value: etaLabel(estimate),
                        label: "Estimated left"
                    )
                }
            }
        }
        .padding(.horizontal, HozzMetrics.gutter)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var recordMetric: some View {
        SummaryMetric(
            value: presentation.export.recordCount.formatted(),
            label: "Records"
        )
    }

    private var elapsedMetric: some View {
        SummaryMetric(
            value: durationLabel(exportElapsed),
            label: "Elapsed"
        )
    }

    private var exportElapsed: TimeInterval {
        max(now.timeIntervalSince(presentation.exportStartedAt), 0)
    }

    private var remainingEstimate: ClosedRange<TimeInterval>? {
        guard
            let estimate = presentation.estimatedRemainingSeconds,
            let capturedAt = presentation.estimateCapturedAt
        else {
            return nil
        }

        let elapsed = max(now.timeIntervalSince(capturedAt), 0)
        let lower = max(estimate.lowerBound - elapsed, 0)
        let upper = max(estimate.upperBound - elapsed, 0)
        return upper > 0 ? lower...upper : nil
    }

    private func etaLabel(_ estimate: ClosedRange<TimeInterval>) -> String {
        let lower = durationLabel(estimate.lowerBound, rounding: .up)
        let upper = durationLabel(estimate.upperBound, rounding: .up)
        return lower == upper ? upper : "\(lower)–\(upper)"
    }
}

private struct SummaryMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(HozzPalette.ink)
            Text(label).hozzLabel().textCase(.uppercase)
        }
    }
}

// MARK: - After an export stops

/// The shape every "the export is not running right now" screen shares: one
/// large icon, a headline, a sentence, and what to do next.
///
/// Written once because there are four of them, they were each drawn by hand,
/// and they had drifted into four different vertical rhythms.
struct ExportOutcomeView<Actions: View>: View {
    let icon: HozzIcon
    let tone: HozzTone
    let title: String
    let message: String
    let detail: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 24)

                HozzIconView(icon, size: 56)
                    .foregroundStyle(tone.color)

                VStack(spacing: 8) {
                    Text(title)
                        .hozzDisplay(size: 28)
                        .multilineTextAlignment(.center)
                    Text(message)
                        .hozzBody(size: 15)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let detail {
                    Text(detail)
                        .hozzCaption()
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actions
                    .padding(.top, 4)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, HozzMetrics.gutter)
        }
        .background(HozzSurface())
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ExportPausedView: View {
    let pause: HealthExportPause
    let resumeAction: () -> Void
    let discardAction: () -> Void

    var body: some View {
        ExportOutcomeView(
            icon: icon,
            tone: .action,
            title: "Export paused",
            message: message,
            detail: "\(pause.recordCount.formatted()) records saved. Continue without duplicates."
        ) {
            VStack(spacing: 10) {
                Button(action: resumeAction) {
                    HStack(spacing: 8) {
                        HozzIconView(.play, size: 17)
                        Text("Continue export")
                    }
                }
                .buttonStyle(.hozzFilled)

                Button("Discard", role: .destructive, action: discardAction)
                    .buttonStyle(.hozzQuiet(tone: .warning))
            }
        }
    }

    private var icon: HozzIcon {
        switch pause.reason {
        case .deviceLocked: .lock
        case .checkpointed: .pause
        }
    }

    private var message: String {
        switch pause.reason {
        case .deviceLocked:
            "Unlock this iPhone to continue."
        case .checkpointed:
            "Progress is saved."
        }
    }
}

struct ExportReadyView: View {
    let result: HealthExportResult
    let newExportAction: () -> Void
    @State private var showsDetails = false

    var body: some View {
        ExportOutcomeView(
            icon: hasErrors ? .alertTriangle : .circleCheck,
            tone: hasErrors ? .warning : .positive,
            title: hasErrors ? "Export ready with warnings" : "Export ready",
            message: "\(result.recordCount.formatted()) records · "
                + Int64(clamping: result.fileByteCount)
                    .formatted(.byteCount(style: .file)),
            detail: nil
        ) {
            VStack(spacing: 14) {
                details

                ShareLink(item: result.fileURL) {
                    HStack(spacing: 8) {
                        HozzIconView(.upload, size: 17)
                        Text("Save or share export")
                    }
                }
                .buttonStyle(.hozzFilled)

                Button("New export", action: newExportAction)
                    .buttonStyle(.hozzQuiet)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsDetails.toggle()
                }
            } label: {
                HStack {
                    Text("Export details").hozzLabel().textCase(.uppercase)
                    Spacer(minLength: 0)
                    HozzIconView(
                        showsDetails ? .chevronDown : .chevronRight,
                        size: 14
                    )
                    .foregroundStyle(HozzPalette.inkMuted)
                }
            }
            .buttonStyle(.plain)

            if showsDetails {
                VStack(alignment: .leading, spacing: 9) {
                    DetailLine(
                        "Types with records",
                        value: result.nonEmptyTypeCount.formatted()
                    )
                    DetailLine(
                        "Types with no records",
                        value: result.zeroResultTypeCount.formatted()
                    )
                    if result.failedTypeCount > 0 {
                        DetailLine(
                            "Types that failed",
                            value: result.failedTypeCount.formatted()
                        )
                    }
                    if result.sampleEncodingErrorCount > 0 {
                        DetailLine(
                            "Samples that failed",
                            value: result.sampleEncodingErrorCount.formatted()
                        )
                    }
                    if result.wasResumed {
                        DetailLine("Resumed", value: "Yes")
                    }

                    Text(
                        "Apple cannot distinguish an empty type from one you did "
                        + "not share, so both are marked indeterminate."
                    )
                    .hozzCaption()
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                }
            }
        }
        .hozzCard()
    }

    private var hasErrors: Bool {
        result.failedTypeCount > 0 || result.sampleEncodingErrorCount > 0
    }
}

private struct DetailLine: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(HozzPalette.inkSoft)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(HozzPalette.ink)
        }
    }
}

/// Shown while an export is queued behind whatever already holds the writer.
///
/// This screen exists because of a real report: someone opened Hozz, found it
/// not running, pressed Export, and was told "an export is already running"
/// with only a Try again button. Two things were wrong. The activity was named
/// incorrectly — an automatic sync held the writer, not an export — and Try
/// again was the only thing offered, which could not work until the sync had
/// finished and gave no way to know when that would be.
struct ExportWaitingView: View {
    let owner: ExportWriterLease.Owner
    let cancelAction: () -> Void

    var body: some View {
        ExportOutcomeView(
            icon: .hourglass,
            tone: .action,
            title: "Waiting to start",
            message: "\(owner.activityDescription) Export starts next.",
            detail: nil
        ) {
            Button("Cancel", action: cancelAction)
                .buttonStyle(.hozzQuiet)
        }
    }
}

struct ExportFailureView: View {
    let message: String
    let tryAgainAction: () -> Void

    var body: some View {
        ExportOutcomeView(
            icon: .alertTriangle,
            tone: .warning,
            title: "Export stopped",
            message: message,
            detail: nil
        ) {
            Button("Try again", action: tryAgainAction)
                .buttonStyle(.hozzFilled)
        }
    }
}

// MARK: - Shared

func durationLabel(
    _ seconds: TimeInterval,
    rounding: FloatingPointRoundingRule = .down
) -> String {
    guard seconds >= 60 else {
        return "<1 min"
    }

    let minutes = Int((seconds / 60).rounded(rounding))
    guard minutes >= 60 else {
        return "\(minutes) min"
    }

    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
}
