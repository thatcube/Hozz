import HozzCore
import HozzDeliver
import HozzUI
import SwiftUI
import UniformTypeIdentifiers

/// Creates or edits one destination.
///
/// The setup failures people actually hit are a wrong URL and a wrong auth
/// header, and they find out days later when no data arrived. The Test button
/// exists to collapse that into a single tap with a readable answer.
struct DestinationEditorView: View {
    let model: SyncViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var kind: DestinationKind
    @State private var format: DeliveryFormat
    @State private var cadence: SyncCadence
    @State private var deliveryWindow: DeliveryWindow
    @State private var isEnabled: Bool
    @State private var endpoint: String
    @State private var secret: String
    @State private var folderBookmark: Data?
    @State private var folderName: String?
    @State private var isPickingFolder = false
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var includedTypes: Set<HealthTypeKey>
    @State private var isPickingTypes = false
    @State private var measurement: String
    @State private var precision: InfluxLineProtocol.Precision
    @State private var payloadSchema: PayloadSchema
    @State private var requestTimeout: TimeInterval
    @State private var maxRequestBytes: Int?
    @State private var unitChoices: [UnitFamily: String]
    @State private var discovered: [DiscoveredReceiver] = []
    @State private var isBrowsing = false

    private let browser = ReceiverBrowser()

    private let existing: Destination?
    private let preset: DestinationPreset?

    init(
        model: SyncViewModel,
        destination: Destination?,
        preset: DestinationPreset? = nil
    ) {
        self.model = model
        self.existing = destination
        self.preset = preset
        _name = State(initialValue: destination?.name ?? preset?.defaultName ?? "")
        _kind = State(initialValue: destination?.kind ?? preset?.kind ?? .folder)
        _format = State(initialValue: destination?.format ?? preset?.format ?? .ndjson)
        _cadence = State(initialValue: destination?.cadence ?? .whenDataArrives)
        _deliveryWindow = State(
            initialValue: destination?.deliveryWindow ?? .sinceLastDelivery
        )
        _isEnabled = State(initialValue: destination?.isEnabled ?? true)
        _endpoint = State(initialValue: destination?.endpointURL?.absoluteString ?? "")
        _secret = State(initialValue: "")
        _folderBookmark = State(initialValue: destination?.folderBookmark)
        _folderName = State(initialValue: destination?.folderBookmark.flatMap(Self.folderName))
        _includedTypes = State(initialValue: destination?.includedTypes ?? [])
        let options = destination?.influxOptions
            ?? InfluxLineProtocol.Options(
                measurement: preset?.options[Destination.measurementKey]
                    ?? InfluxLineProtocol.defaultMeasurement
            )
        _measurement = State(initialValue: options.measurement)
        _precision = State(initialValue: options.precision)
        _payloadSchema = State(initialValue: destination?.payloadSchema ?? .hozz)
        _requestTimeout = State(
            initialValue: destination?.requestTimeout ?? RequestTimeout.default
        )
        _maxRequestBytes = State(initialValue: destination?.maxRequestBytes)
        _unitChoices = State(
            initialValue: destination?.unitPreferences.units ?? [:]
        )
    }

    var body: some View {
        Form {
            // One modifier rather than fourteen. Applied to the builder's
            // whole tuple, `listRowBackground` reaches every section under
            // it, so a section added later cannot quietly forget to be the
            // right colour — which is exactly how the app came to have two
            // looks in the first place.
            formContent
                .hozzFormRows()
        }
        .hozzFormChrome()
        .navigationTitle(existing == nil ? "New destination" : "Destination")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Browsing prompts for local network access, so it starts only on
            // the screen where an address is actually being chosen.
            isBrowsing = true
            await browser.onChange { receivers in
                Task { @MainActor in
                    discovered = receivers
                    if !receivers.isEmpty {
                        isBrowsing = false
                    }
                }
            }
            await browser.start()
        }
        .onDisappear {
            Task { await browser.stop() }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .tint(HozzPalette.blue)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(!isValid)
                .tint(HozzPalette.blue)
            }
        }
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder]
        ) { result in
            handleFolderSelection(result)
        }
        .sheet(isPresented: $isPickingTypes) {
            NavigationStack {
                TypePickerView(selection: includedTypes) { selection in
                    includedTypes = selection
                }
            }
        }
    }

    @ViewBuilder
    private var formContent: some View {
            if let preset {
                Section {
                    ForEach(Array(preset.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(HozzPalette.blue)
                                .frame(width: 18, height: 18)
                                .background(
                                    HozzPalette.iconWell,
                                    in: Circle()
                                )
                            Text(step)
                                .font(.footnote)
                                .foregroundStyle(HozzPalette.inkSoft)
                        }
                    }

                    if let caveat = preset.caveat {
                        HozzLabel(.infoCircle, size: 16) {
                            Text(caveat)
                                .font(.footnote)
                                .foregroundStyle(HozzPalette.inkSoft)
                        }
                    }
                } header: {
                    Text("Setting up \(preset.displayName)")
                        .hozzFormHeader()
                }
            } else {
                Section {
                    Picker("Send to", selection: $kind) {
                        ForEach(DestinationKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(existing != nil)

                    Text(kindExplanation)
                        .font(.footnote)
                        .foregroundStyle(HozzPalette.inkSoft)
                }
            }

            switch kind {
            case .folder:
                folderSection
            case .restAPI, .mqtt:
                endpointSection
            }

            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)

                Picker("Format", selection: $format) {
                    ForEach(availableFormats, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .onChange(of: kind) { _, newKind in
                    // Not every format suits every kind, and leaving a stale
                    // one selected would save a destination that writes bytes
                    // its receiver quietly ignores.
                    let available = DeliveryFormat.available(for: newKind)
                    if !available.contains(format) {
                        format = available.first ?? .ndjson
                    }
                }

                Picker("How often", selection: $cadence) {
                    ForEach(SyncCadence.allCases, id: \.self) { cadence in
                        Text(cadence.displayName).tag(cadence)
                    }
                }

                Button {
                    isPickingTypes = true
                } label: {
                    HStack {
                        Text("Data types")
                            .foregroundStyle(HozzPalette.ink)
                        Spacer()
                        Text(includedTypes.isEmpty ? "Everything" : "\(includedTypes.count)")
                            .foregroundStyle(HozzPalette.inkSoft)
                        HozzIconView(.chevronRight, size: 14)
                            .foregroundStyle(HozzPalette.inkMuted)
                    }
                }

                Toggle("Enabled", isOn: $isEnabled)
            } header: {
                Text("Details")
                    .hozzFormHeader()
            } footer: {
                Text(formatExplanation)
            }

            windowSection

            if let unsupported = existing?.unsupportedDescription {
                Section {
                    HozzLabel(.alertTriangle, size: 16) {
                        Text(unsupported)
                            .font(.footnote)
                            .foregroundStyle(HozzPalette.inkSoft)
                    }
                } header: {
                    Text("Not understood by this version")
                        .hozzFormHeader()
                } footer: {
                    // Saying this plainly matters: saving is the escape hatch,
                    // and it is also the moment the original setting is
                    // replaced. Someone should be able to decide to wait.
                    Text(
                        "Saving replaces that setting with the one chosen "
                        + "above. If you would rather keep it until Hozz can "
                        + "read it again, leave this screen without saving."
                    )
                }
            }

            if format == .influx {
                influxSection
            }

            if kind == .restAPI {
                timeoutSection
                requestSizeSection
            }

            if PayloadUnits.applies(to: format) {
                unitsSection
            }

            if PayloadSchema.applies(to: format), kind != .folder {
                compatibilitySection
            }

            if let testResult {
                Section {
                    Text(testResult)
                        .font(.system(size: 13))
                        .foregroundStyle(HozzPalette.inkSoft)
                        .textSelection(.enabled)
                } header: {
                    Text("Test result").hozzFormHeader()
                }
            }

            Section {
                Button {
                    Task { await runTest() }
                } label: {
                    HStack {
                        if isTesting {
                            ProgressView()
                        } else {
                            HozzIconView(.send, size: 20)
                        }
                        Text("Send a test")
                    }
                }
                .disabled(!isValid || isTesting)
            } footer: {
                Text(
                    "Sends one tiny file so you can confirm this works now, "
                    + "instead of finding out days later."
                )
            }
    }

    private var availableFormats: [DeliveryFormat] {
        DeliveryFormat.available(for: kind)
    }

    /// How far back this destination is willing to be sent.
    ///
    /// Given its own section rather than tucked in with the cadence, because the
    /// two are easy to confuse and only one of them can leave a reading out.
    /// "How often" is when Hozz tries; this is what it is allowed to send.
    private var windowSection: some View {
        Section {
            Picker("Start from", selection: $deliveryWindow) {
                ForEach(DeliveryWindow.allCases, id: \.self) { window in
                    Text(window.displayName).tag(window)
                }
            }

            Text(deliveryWindow.explanation)
                .font(.footnote)
                .foregroundStyle(HozzPalette.inkSoft)

            if let date = previewFloor.date {
                // The actual date, because "7 days ago" stops being true the
                // day after it is chosen and this one does not move.
                Text(
                    "Nothing dated before \(date.formatted(date: .abbreviated, time: .shortened))."
                )
                .font(.footnote)
                .foregroundStyle(HozzPalette.inkSoft)
            }

            if willReplayHistory {
                HozzLabel(.infoCircle, size: 16) {
                    Text(
                        "Saving this will send everything again from the "
                        + "beginning. Readings the later starting point skipped "
                        + "are still in this iPhone's Health, so moving it back "
                        + "does not leave them behind — but the destination will "
                        + "receive a lot at once. Each one carries the same "
                        + "identifier as before, so anything that stores them "
                        + "by identifier keeps one copy."
                    )
                    .font(.footnote)
                    .foregroundStyle(HozzPalette.inkSoft)
                }
            }
        } header: {
            Text("Where to start")
                .hozzFormHeader()
        } footer: {
            Text(
                "Separate from how often Hozz syncs. Hozz reads Health with a "
                + "bookmark rather than a date, so a reading the Health app "
                + "files under last week is still noticed — but anything dated "
                + "before the starting point is not delivered to this "
                + "destination, and is not delivered later either. The date is "
                + "worked out once and then kept, so it never creeps forward "
                + "and leaves last night behind. Choosing an earlier starting "
                + "point sends everything again from the beginning, so nothing "
                + "is out of reach for good."
            )
        }
    }

    /// Whether saving would move the starting point earlier and therefore
    /// replay everything.
    ///
    /// Worth saying before the fact rather than after. Moving it earlier is the
    /// right thing to allow — it is the only way readings a later starting point
    /// skipped are ever sent — but somebody pointing this at a home server
    /// should know a backlog is about to arrive.
    private var willReplayHistory: Bool {
        guard let existing else {
            return false
        }
        return !existing.deliveryFloor.covers(previewFloor)
    }

    /// The starting point that saving would put in force.
    ///
    /// Mirrors what `DeliveryEngine.save` will do: an unchanged choice keeps the
    /// date already in force, and a changed one is resolved from now.
    private var previewFloor: DeliveryFloor {
        guard deliveryWindow.isBounded else {
            return .unbounded
        }
        if existing?.deliveryWindow == deliveryWindow {
            return existing?.deliveryFloor ?? .unbounded
        }
        return DeliveryFloor(date: deliveryWindow.floor(now: .now))
    }

    private var addressPrecision: InfluxLineProtocol.Precision? {
        InfluxLineProtocol.declaredPrecision(in: URL(string: endpoint))
    }

    /// Everything InfluxDB needs that does not fit in the address.
    private var influxSection: some View {
        Section {
            TextField("Measurement", text: $measurement)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Picker("Timestamp precision", selection: $precision) {
                ForEach(InfluxLineProtocol.Precision.allCases, id: \.self) { precision in
                    Text(precision.displayName).tag(precision)
                }
            }

            if let declared = addressPrecision, declared != precision {
                HozzLabel(.alertTriangle, size: 16) {
                    Text(
                        "The address says precision=\(declared.rawValue) but this "
                        + "is set to \(precision.rawValue). InfluxDB will not "
                        + "complain — it will file every point in the wrong "
                        + "decade. Make them match."
                    )
                    .font(.footnote)
                    .foregroundStyle(HozzPalette.warning)
                }
            }
        } header: {
            Text("InfluxDB")
                .hozzFormHeader()
        } footer: {
            Text(
                "Every sample is written to this measurement, tagged with its "
                + "type, source, device, and unit. The precision has to match "
                + "the precision in the address: InfluxDB does not complain "
                + "about a mismatch, it just files every point in the wrong "
                + "decade. InfluxDB 2.x and 3.x expect /api/v2/write with org, "
                + "bucket, and precision in the address and a Token "
                + "authorization header; 1.8 expects /write?db=yourdatabase."
            )
        }
    }

    /// How long to wait for the endpoint to answer.
    ///
    /// Offered for endpoints only. A folder is the file system and an MQTT
    /// broker answers in milliseconds or not at all; the request that hangs is
    /// always the HTTP one to somebody's own computer.
    private var timeoutSection: some View {
        Section {
            Picker("Wait for a reply", selection: $requestTimeout) {
                ForEach(RequestTimeout.choices, id: \.self) { seconds in
                    Text(RequestTimeout.displayName(for: seconds)).tag(seconds)
                }
            }

            Text(RequestTimeout.explanation(for: requestTimeout))
                .font(.footnote)
                .foregroundStyle(HozzPalette.inkSoft)
        } header: {
            Text("Timeout")
                .hozzFormHeader()
        } footer: {
            Text(
                "A large batch posted to a small computer can take minutes to "
                + "be accepted. Giving up too early reports a server that is "
                + "working as one that is broken, and the batch is retried "
                + "anyway, so nothing is lost either way \u{2014} only time."
            )
        }
    }


    /// Whether to split a large batch across several requests.
    ///
    /// Off unless asked for. Splitting changes how many requests an existing
    /// destination receives, and a setup that works today should go on working
    /// untouched after an update.
    private var requestSizeSection: some View {
        Section {
            Picker("Largest request", selection: $maxRequestBytes) {
                Text("Send it all at once").tag(Int?.none)
                ForEach(RequestSize.choices, id: \.self) { bytes in
                    Text(RequestSize.displayName(for: bytes)).tag(Int?.some(bytes))
                }
            }

            if let maxRequestBytes {
                Text(RequestSize.explanation(for: maxRequestBytes))
                    .font(.footnote)
                    .foregroundStyle(HozzPalette.inkSoft)
            }
        } header: {
            Text("Request size")
                .hozzFormHeader()
        } footer: {
            Text(
                "If your server answers HTTP 413, or times out on a big batch, "
                + "its limit is smaller than what Hozz is sending. nginx "
                + "refuses anything over 1 MB unless told otherwise. Splitting "
                + "sends the same readings in several requests instead. If one "
                + "of them fails, Hozz stops there, counts none of the batch as "
                + "delivered, and sends the whole thing again next time, so a "
                + "half-arrived batch is never recorded as a success."
            )
        }
    }

    /// Which units this destination should receive.
    ///
    /// Offered per group rather than per reading, because a person has one
    /// opinion about distance and one about weight, not a hundred. Distance and
    /// body measurements are separate on purpose: someone who wants their runs
    /// in miles does not want their height in miles.
    private var unitsSection: some View {
        Section {
            Button("Use the units for my region") {
                unitChoices = UnitPreferences.forRegion().units
            }

            if !unitChoices.isEmpty {
                Button("Leave every value as Health gives it", role: .destructive) {
                    unitChoices = [:]
                }
            }

            ForEach(UnitFamily.allCases, id: \.self) { family in
                Picker(family.displayName, selection: binding(for: family)) {
                    Text("As Health gives it").tag(String?.none)
                    ForEach(family.choices, id: \.self) { unit in
                        Text(UnitFamily.displayName(forUnit: unit))
                            .tag(String?.some(unit))
                    }
                }
            }
        } header: {
            Text("Units")
                .hozzFormHeader()
        } footer: {
            Text(unitsExplanation)
        }
    }

    /// Split out of the view because the compiler will not type-check a string
    /// this long spliced together inline in reasonable time — it builds on the
    /// simulator and times out for the device, which is a poor way to find out.
    private var unitsExplanation: String {
        "Every value Hozz sends carries its own unit, so a reading can never be "
            + "read as something it is not \u{2014} a converted one also says "
            + "what it was converted from. Changing this does not rewrite "
            + "anything already delivered, so a receiver storing a long history "
            + "will hold both, each labelled correctly."
    }

    private func binding(for family: UnitFamily) -> Binding<String?> {
        Binding(
            get: { unitChoices[family] },
            set: { unitChoices[family] = $0 }
        )
    }

    /// Matching another exporter's field names, for pipelines already built.
    private var compatibilitySection: some View {
        Section {
            Picker("Field names", selection: $payloadSchema) {
                ForEach(PayloadSchema.allCases, id: \.self) { schema in
                    Text(schema.displayName).tag(schema)
                }
            }
        } header: {
            Text("Field names")
                .hozzFormHeader()
        } footer: {
            Text(
                payloadSchema == .hozz
                    ? "Hozz's own schema, which is what the documentation "
                    + "describes and what to build anything new against."
                    : "Sends the field names Health Auto Export publishes, so an "
                    + "automation or dashboard already built for it keeps "
                    + "working. Dates become local time in their format rather "
                    + "than ISO 8601. Hozz sends individual samples rather than "
                    + "summaries, so a heart rate point carries the same number "
                    + "in Min, Avg, and Max."
            )
        }
    }

    private var folderSection: some View {
        Section {
            Button {
                isPickingFolder = true
            } label: {
                HozzLabel(.folderOpen) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folderName ?? "Choose a folder")
                        if folderName != nil {
                            Text("Tap to change")
                                .font(.caption)
                                .foregroundStyle(HozzPalette.inkSoft)
                        }
                    }
                }
            }
        } header: {
            Text("Folder")
                .hozzFormHeader()
        } footer: {
            Text(
                "Pick anywhere the Files app can reach — iCloud Drive, Dropbox, "
                + "OneDrive, Google Drive, or a server on your network. Whatever "
                + "already syncs that folder to your computer does the rest, so "
                + "this keeps working even while your computer is switched off."
            )
        }
    }

    private var endpointSection: some View {
        Section {
            if kind == .restAPI {
                discoveredReceivers
            }

            TextField(preset?.addressPlaceholder ?? "https://example.com/health", text: $endpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            SecureField(preset?.secretPlaceholder ?? "Authorization header (optional)", text: $secret)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text(kind == .mqtt ? "Broker" : "Web address")
                .hozzFormHeader()
        } footer: {
            Text(
                "Hozz posts batches here and includes an idempotency key, so a "
                + "retry after a dropped connection is never stored twice. The "
                + "token is kept in this iPhone's Keychain and never written to "
                + "a file, a backup, or a log."
            )
        }
    }

    /// Hozz receivers advertising on the same network.
    ///
    /// Offered before the address field rather than after it, because typing an
    /// address is the step people abandon — and a home IP address changes
    /// without warning, so one typed today silently stops working later.
    @ViewBuilder
    private var discoveredReceivers: some View {
        if !discovered.isEmpty {
            ForEach(discovered) { receiver in
                Button {
                    endpoint = receiver.url
                } label: {
                    HStack(spacing: 11) {
                        HozzIconView(.deviceDesktop, size: 20)
                            .foregroundStyle(HozzPalette.blue)
                        Text(receiver.name)
                            .foregroundStyle(HozzPalette.ink)
                        Spacer()
                        if endpoint == receiver.url {
                            HozzIconView(.check, size: 17)
                                .foregroundStyle(HozzPalette.blue)
                        }
                    }
                }
            }
        } else if isBrowsing {
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking for Hozz on this network…")
                    .foregroundStyle(HozzPalette.inkSoft)
            }
        }
    }

    private var kindExplanation: LocalizedStringKey {
        switch kind {
        case .folder:
            "Easiest. No server to run, and it works away from home."
        case .restAPI:
            "For a database or a service you run yourself."
        case .mqtt:
            "For a broker on your network."
        }
    }

    private var formatExplanation: LocalizedStringKey {
        switch format {
        case .ndjson:
            "One record per line. Keeps everything Health returned."
        case .json:
            "One array per batch. Easy to read and to feed to other tools."
        case .csv:
            "A spreadsheet. Drops metadata and workout detail."
        case .metrics:
            "Grouped by metric, with the latest value for each. What Home Assistant, Grafana, and most dashboards expect."
        case .influx:
            "InfluxDB line protocol, written straight into InfluxDB or Telegraf. No translator in between."
        }
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        switch kind {
        case .folder:
            return folderBookmark != nil
        case .restAPI:
            guard let url = URL(string: endpoint), url.host != nil else {
                return false
            }
            return url.scheme == "https" || url.scheme == "http"
        case .mqtt:
            guard let url = URL(string: endpoint), url.host != nil else {
                return false
            }
            return url.scheme == "mqtt" || url.scheme == "mqtts"
        }
    }

    private func handleFolderSelection(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else {
            return
        }
        // The picker hands back a security-scoped URL. A bookmark is what lets
        // Hozz write there again later, including from a background launch.
        guard url.startAccessingSecurityScopedResource() else {
            testResult = "Hozz could not get permission for that folder."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            folderBookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            folderName = url.lastPathComponent
            if name.isEmpty {
                name = url.lastPathComponent
            }
        } catch {
            testResult = error.localizedDescription
        }
    }

    private func build() -> Destination {
        Destination(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            kind: kind,
            format: format,
            cadence: cadence,
            isEnabled: isEnabled,
            folderBookmark: folderBookmark,
            endpointURL: kind == .folder ? nil : URL(string: endpoint),
            headers: existing?.headers ?? [:],
            includedTypes: includedTypes,
            payloadSchema: PayloadSchema.applies(to: format) ? payloadSchema : .hozz,
            deliveryWindow: deliveryWindow,
            options: options,
            createdAt: existing?.createdAt ?? .now
        )
    }

    /// Settings that belong to the destination but are not headers or secrets.
    ///
    /// Anything already stored is kept, so switching format away from InfluxDB
    /// and back does not lose a measurement name that was typed once.
    private var options: [String: String] {
        var options = existing?.options ?? [:]
        for family in UnitFamily.allCases {
            options[family.settingKey] = unitChoices[family]
        }
        if kind == .restAPI {
            options[Destination.timeoutKey] = String(Int(requestTimeout))
            // Removed rather than set to zero when switched off, so the record
            // says nothing rather than saying something meaningless.
            options[Destination.maxRequestBytesKey] = maxRequestBytes.map(String.init)
        }
        guard format == .influx || options[Destination.measurementKey] != nil else {
            // A folder has no measurement name, and stamping one on it would
            // put settings in the record that mean nothing there.
            return options
        }
        let trimmed = measurement.trimmingCharacters(in: .whitespaces)
        options[Destination.measurementKey] = trimmed.isEmpty
            ? InfluxLineProtocol.defaultMeasurement
            : trimmed
        options[Destination.precisionKey] = precision.rawValue
        return options
    }

    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        testResult = await model.test(build(), secret: secret.isEmpty ? nil : secret)
    }

    private func save() async {
        await model.save(build(), secret: secret.isEmpty ? nil : secret)
        dismiss()
    }

    private static func folderName(from bookmark: Data) -> String? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ).lastPathComponent
    }
}
