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
    }

    var body: some View {
        Form {
            if let preset {
                Section {
                    ForEach(Array(preset.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(HozzPalette.action)
                                .frame(width: 18, height: 18)
                                .background(
                                    HozzPalette.action.opacity(0.15),
                                    in: Circle()
                                )
                            Text(step)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let caveat = preset.caveat {
                        HozzLabel(.infoCircle, size: 16) {
                            Text(caveat)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Setting up \(preset.displayName)")
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
                        .foregroundStyle(.secondary)
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
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(includedTypes.isEmpty ? "Everything" : "\(includedTypes.count)")
                            .foregroundStyle(.secondary)
                        HozzIconView(.chevronRight, size: 14)
                            .foregroundStyle(.tertiary)
                    }
                }

                Toggle("Enabled", isOn: $isEnabled)
            } header: {
                Text("Details")
            } footer: {
                Text(formatExplanation)
            }

            if format == .influx {
                influxSection
            }

            if PayloadSchema.applies(to: format), kind != .folder {
                compatibilitySection
            }

            if let testResult {
                Section("Test result") {
                    Text(testResult)
                        .font(.footnote)
                        .textSelection(.enabled)
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
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(!isValid)
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

    private var availableFormats: [DeliveryFormat] {
        DeliveryFormat.available(for: kind)
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
        } header: {
            Text("InfluxDB")
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
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Folder")
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
                    HStack {
                        Label(receiver.name, systemImage: "desktopcomputer")
                            .foregroundStyle(.primary)
                        Spacer()
                        if endpoint == receiver.url {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        } else if isBrowsing {
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking for Hozz on this network…")
                    .foregroundStyle(.secondary)
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
