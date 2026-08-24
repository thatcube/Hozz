import HozzHealth
import HozzUI
import SwiftUI

struct RootView: View {
    @State private var model: ExportViewModel
    @State private var syncModel = SyncViewModel()
    @Environment(\.scenePhase) private var scenePhase
    private let healthDataAvailable: Bool

    init(healthDataAvailable: Bool = HealthKitAvailability.isAvailable) {
        self.healthDataAvailable = healthDataAvailable
        _model = State(initialValue: ExportViewModel())
    }

    var body: some View {
        #if DEBUG
        if DashboardHarnessLaunch.isRequested {
            DashboardDesignHarness()
        } else {
            tabs
        }
        #else
        tabs
        #endif
    }

    private var tabs: some View {
        TabView {
            NavigationStack {
                DashboardView()
            }
            .tabItem {
                Label {
                    Text("Health")
                } icon: {
                    Image(HozzIcon.chartLine.rawValue).renderingMode(.template)
                }
            }

            NavigationStack {
                SyncDashboardView(model: syncModel)
            }
            .tabItem {
                Label {
                    Text("Automatic")
                } icon: {
                    Image(HozzIcon.refresh.rawValue).renderingMode(.template)
                }
            }

            NavigationStack {
                exportFlow
            }
            .tabItem {
                Label {
                    Text("Export")
                } icon: {
                    Image(HozzIcon.download.rawValue).renderingMode(.template)
                }
            }

            NavigationStack {
                AboutView()
            }
            .tabItem {
                Label {
                    Text("About")
                } icon: {
                    Image(HozzIcon.infoCircle.rawValue).renderingMode(.template)
                }
            }
        }
        .tint(HozzPalette.action)
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
            if phase == .active {
                Task { await syncModel.load() }
            }
        }
    }

    @ViewBuilder
    private var exportFlow: some View {
        switch model.state {
        case .idle, .requestingAccess:
            ExportSetupView(
                healthDataAvailable: healthDataAvailable,
                isRequestingAccess: model.isWorking,
                exportFormat: model.exportFormat,
                resumable: model.resumable,
                selectExportFormat: model.selectExportFormat,
                exportAction: model.exportNow,
                discardAction: model.discardResumableRun
            )
            .task { await model.prepare() }
        case .exporting(let presentation):
            ExportSessionView(
                presentation: presentation,
                exportFormat: model.exportFormat,
                pauseAction: model.pause
            )
        case .waitingForWriter(let owner):
            ExportWaitingView(
                owner: owner,
                cancelAction: model.pause
            )
        case .paused(let pause):
            ExportPausedView(
                pause: pause,
                resumeAction: model.exportNow,
                discardAction: model.discardResumableRun
            )
        case .ready(let result):
            ExportReadyView(
                result: result,
                newExportAction: model.prepareNewExport
            )
        case .failed(let message):
            ExportFailureView(
                message: message,
                tryAgainAction: model.prepareNewExport
            )
        }
    }
}

private struct ExportSetupView: View {
    let healthDataAvailable: Bool
    let isRequestingAccess: Bool
    let exportFormat: HealthExportFormat
    let resumable: ExportViewModel.ResumableSummary?
    let selectExportFormat: (HealthExportFormat) -> Void
    let exportAction: () -> Void
    let discardAction: () -> Void

    var body: some View {
        Form {
            Section {
                SetupIntroduction()

                if !healthDataAvailable {
                    Label(
                        "Apple Health is unavailable or restricted on this device.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

            if let resumable {
                Section("Unfinished export") {
                    if let obstruction = resumable.obstruction {
                        // Shown rather than hidden. An unfinished export that
                        // disappears with nothing said is worse than one that
                        // explains why it is stuck.
                        Label(obstruction, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label(
                            "\(resumable.recordCount.formatted()) records are already saved. Exporting continues from there.",
                            systemImage: "arrow.clockwise"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    Button("Discard unfinished export", role: .destructive) {
                        discardAction()
                    }
                }
            }

            Section("Format") {
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
                // The unfinished run dictates the format only while it can
                // actually be continued.
                .disabled(resumable?.canContinue == true)

                Label(formatNote, systemImage: formatIcon)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if exportFormat.coversRoutesOnly {
                    // Not a footnote. Someone picking this expecting a health
                    // export gets an archive that looks broken, and finding
                    // that out afterwards is the whole problem.
                    Label(
                        "GPX holds routes only. This exports workouts that "
                        + "recorded GPS and nothing else — no heart rate, no "
                        + "sleep, no weight. Choose NDJSON or SQLite for "
                        + "everything.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }

                if resumable?.canContinue == true {
                    // Changing format now would throw away everything the
                    // unfinished run has already sealed, so the choice belongs
                    // to that run until it finishes or is discarded.
                    Label(
                        "The unfinished export above set this format. Discard it to choose another.",
                        systemImage: "lock"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Current coverage") {
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
                CoverageRow(
                    "Correlations and documents",
                    available: false
                )
            }

            Section {
                Link("Source code", destination: HozzLinks.source)
                Link("Support development", destination: HozzLinks.sponsors)
                Link("More free apps", destination: HozzLinks.developer)
            }
        }
        .navigationTitle("Hozz")
        .safeAreaInset(edge: .bottom) {
            Button(action: exportAction) {
                HStack {
                    if isRequestingAccess {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text(buttonTitle)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!healthDataAvailable || isRequestingAccess)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var formatNote: LocalizedStringKey {
        switch exportFormat {
        case .ndjson:
            "One record per line. Keeps everything Health returned."
        case .csv:
            "A spreadsheet per data type. Drops metadata and workout details."
        case .json:
            "One array. Easiest to read, heaviest to open when large."
        case .sqlite:
            "A database you can query. Keeps every record as it was written."
        case .markdown:
            "A note per day for Obsidian. Drops the records behind the totals."
        case .gpx:
            "One GPX track per workout with GPS, for maps and fitness tools."
        case .raw:
            "Uncompressed. Can be several gigabytes."
        }
    }

    private var formatIcon: String {
        switch exportFormat {
        case .ndjson:
            "list.bullet.rectangle"
        case .csv:
            "tablecells"
        case .json:
            "curlybraces"
        case .sqlite:
            "cylinder.split.1x2"
        case .markdown:
            "calendar"
        case .gpx:
            "map"
        case .raw:
            "doc.plaintext"
        }
    }

    private var buttonTitle: LocalizedStringKey {
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

private struct SetupIntroduction: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "heart.text.square.fill")
                .font(.largeTitle)
                .foregroundStyle(HozzPalette.action)

            Text("Export Apple Health")
                .font(.largeTitle.bold())

            Text("Choose your Health access, then save a file directly from this device.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
    }
}

struct CoverageRow: View {
    let title: LocalizedStringResource
    let available: Bool

    init(_ title: LocalizedStringResource, available: Bool) {
        self.title = title
        self.available = available
    }

    var body: some View {
        Label(
            title,
            systemImage: available ? "checkmark.circle.fill" : "clock.badge.exclamationmark"
        )
        .foregroundStyle(available ? .primary : .secondary)
        .symbolRenderingMode(.hierarchical)
    }
}

private struct ExportSessionView: View {
    let presentation: ExportViewModel.ProgressPresentation
    let exportFormat: HealthExportFormat
    let pauseAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ExportSessionHeader(
                presentation: presentation,
                exportFormat: exportFormat
            )
            ExportStepList(
                steps: presentation.steps,
                currentTypeStartedAt: presentation.currentTypeStartedAt
            )
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Exporting")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Pause", role: .cancel, action: pauseAction)
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

        VStack(spacing: 10) {
            ProgressView(
                value: Double(progress.completedTypes),
                total: Double(max(progress.totalTypes, 1))
            )

            ViewThatFits(in: .horizontal) {
                HStack {
                    progressLabel
                    Spacer()
                    formatLabel
                }

                VStack(alignment: .leading, spacing: 6) {
                    progressLabel
                    formatLabel
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var progressLabel: some View {
        Text(
            "\(presentation.export.completedTypes) of "
            + "\(presentation.export.totalTypes) data types"
        )
        .font(.subheadline.weight(.semibold))
    }

    private var formatLabel: some View {
        Label(
            LocalizedStringResource(stringLiteral: exportFormat.displayName),
            systemImage: exportFormat == .raw
                ? "doc.plaintext.fill"
                : "archivebox.fill"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

private struct ExportStepList: View {
    let steps: [ExportViewModel.ExportStep]
    let currentTypeStartedAt: Date
    @State private var showsEmptyTypes = false

    private var emptySteps: [ExportViewModel.ExportStep] {
        steps.filter { $0.state == .indeterminate }
    }

    private var visibleSteps: [ExportViewModel.ExportStep] {
        showsEmptyTypes ? steps : steps.filter { $0.state != .indeterminate }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if !emptySteps.isEmpty {
                    Section {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showsEmptyTypes.toggle()
                            }
                        } label: {
                            HStack {
                                Text("\(emptySteps.count) types with no data")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(showsEmptyTypes ? "Hide" : "Show")
                                    .font(.subheadline)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    ForEach(visibleSteps) { step in
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            ExportStepRow(
                                step: step,
                                currentTypeElapsed: max(
                                    context.date.timeIntervalSince(currentTypeStartedAt),
                                    0
                                )
                            )
                        }
                        .id(step.id)
                        .listRowBackground(
                            step.state == .exporting
                                ? HozzPalette.action.opacity(0.09)
                                : Color(uiColor: .secondarySystemGroupedBackground)
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
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
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.name)
                    .font(.body.weight(step.state == .exporting ? .semibold : .regular))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.state {
        case .exporting:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .indeterminate:
            // Finishing with nothing is a normal, successful outcome for most
            // people on most types, so it reads as done rather than as a
            // problem. The caveat that Apple will not say whether a type was
            // unshared or simply empty is stated once, in the summary.
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.tertiary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var detail: String {
        switch step.state {
        case .exporting:
            "\(step.recordCount.formatted()) records · \(durationLabel(currentTypeElapsed))"
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
            HStack(spacing: 20) {
                recordMetric

                Divider()
                    .frame(height: 30)

                elapsedMetric

                if let estimate = remainingEstimate {
                    Divider()
                        .frame(height: 30)

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
        .padding(.horizontal, 20)
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
    let label: LocalizedStringResource

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ExportPausedView: View {
    let pause: HealthExportPause
    let resumeAction: () -> Void
    let discardAction: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(HozzPalette.action)

            VStack(spacing: 8) {
                Text("Export paused")
                    .font(.largeTitle.bold())
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Text(
                "\(pause.recordCount.formatted()) records are saved. "
                + "Continuing picks up where this left off, with no duplicates."
            )
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)

            Button(action: resumeAction) {
                Label("Continue export", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Discard", role: .destructive, action: discardAction)

            Spacer()
        }
        .padding(24)
        .navigationTitle("Hozz")
    }

    private var icon: String {
        switch pause.reason {
        case .deviceLocked:
            "lock.fill"
        case .checkpointed:
            "pause.circle.fill"
        }
    }

    private var message: LocalizedStringKey {
        switch pause.reason {
        case .deviceLocked:
            "Health is locked. Unlock this iPhone and Hozz will continue."
        case .checkpointed:
            "Hozz saved its progress so nothing has to be read twice."
        }
    }
}

private struct ExportReadyView: View {
    let result: HealthExportResult
    let newExportAction: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(
                systemName: hasErrors
                    ? "exclamationmark.circle.fill"
                    : "checkmark.circle.fill"
            )
                .font(.system(size: 64))
                .foregroundStyle(hasErrors ? .orange : .green)

            VStack(spacing: 8) {
                Text(hasErrors ? "Export ready with warnings" : "Export ready")
                    .font(.largeTitle.bold())
                Text(
                    "\(result.recordCount.formatted()) records · "
                    + Int64(clamping: result.fileByteCount)
                        .formatted(.byteCount(style: .file))
                )
                .foregroundStyle(.secondary)
            }

            DisclosureGroup("Export details") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent(
                        "Types with records",
                        value: result.nonEmptyTypeCount.formatted()
                    )
                    LabeledContent(
                        "Types with no records",
                        value: result.zeroResultTypeCount.formatted()
                    )

                    Text(
                        "Most people have no data for most types, so empty is "
                        + "normal. Apple does not let Hozz tell an empty type "
                        + "from one you did not share, so the export marks "
                        + "those as indeterminate rather than claiming they "
                        + "were read."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if result.failedTypeCount > 0 {
                        LabeledContent(
                            "Types that failed",
                            value: result.failedTypeCount.formatted()
                        )
                    }

                    if result.sampleEncodingErrorCount > 0 {
                        LabeledContent(
                            "Samples that failed",
                            value: result.sampleEncodingErrorCount.formatted()
                        )
                    }

                    if result.wasResumed {
                        LabeledContent("Resumed", value: "Yes")
                    }
                }
                .font(.subheadline)
                .padding(.top, 8)
            }
            .padding()
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )

            ShareLink(item: result.fileURL) {
                Label("Save or share export", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("New export", action: newExportAction)

            Spacer()
        }
        .padding(24)
        .navigationTitle("Hozz")
    }

    private var hasErrors: Bool {
        result.failedTypeCount > 0 || result.sampleEncodingErrorCount > 0
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
private struct ExportWaitingView: View {
    let owner: ExportWriterLease.Owner
    let cancelAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Waiting to start", systemImage: "clock.arrow.circlepath")
        } description: {
            Text(
                """
                \(owner.activityDescription) Your export will start as soon \
                as it finishes.
                """
            )
        } actions: {
            Button("Cancel", action: cancelAction)
                .buttonStyle(.bordered)
        }
        .navigationTitle("Hozz")
    }
}

private struct ExportFailureView: View {
    let message: String
    let tryAgainAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Export stopped", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again", action: tryAgainAction)
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Hozz")
    }
}

private func durationLabel(
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

enum HozzLinks {
    static let source = URL(string: "https://github.com/thatcube/hozz")!
    static let sponsors = URL(string: "https://github.com/sponsors/thatcube")!
    static let developer = URL(string: "https://github.com/thatcube")!
}
