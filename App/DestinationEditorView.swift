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

    private let existing: Destination?

    init(model: SyncViewModel, destination: Destination?) {
        self.model = model
        self.existing = destination
        _name = State(initialValue: destination?.name ?? "")
        _kind = State(initialValue: destination?.kind ?? .folder)
        _format = State(initialValue: destination?.format ?? .ndjson)
        _cadence = State(initialValue: destination?.cadence ?? .whenDataArrives)
        _isEnabled = State(initialValue: destination?.isEnabled ?? true)
        _endpoint = State(initialValue: destination?.endpointURL?.absoluteString ?? "")
        _secret = State(initialValue: "")
        _folderBookmark = State(initialValue: destination?.folderBookmark)
        _folderName = State(initialValue: destination?.folderBookmark.flatMap(Self.folderName))
        _includedTypes = State(initialValue: destination?.includedTypes ?? [])
    }

    var body: some View {
        Form {
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

            switch kind {
            case .folder:
                folderSection
            case .restAPI:
                endpointSection
            }

            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)

                Picker("Format", selection: $format) {
                    ForEach(DeliveryFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
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
            TextField("https://example.com/health", text: $endpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            SecureField("Authorization header (optional)", text: $secret)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Web address")
        } footer: {
            Text(
                "Hozz posts batches here and includes an idempotency key, so a "
                + "retry after a dropped connection is never stored twice. The "
                + "token is kept in this iPhone's Keychain and never written to "
                + "a file, a backup, or a log."
            )
        }
    }

    private var kindExplanation: LocalizedStringKey {
        switch kind {
        case .folder:
            "Easiest. No server to run, and it works away from home."
        case .restAPI:
            "For a database or a service you run yourself."
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
        case .compatible:
            "Matches the Health Auto Export payload, so existing Home Assistant, Grafana, and community server setups keep working."
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
            guard let url = URL(string: endpoint) else {
                return false
            }
            return url.scheme == "https" || url.scheme == "http"
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
            endpointURL: kind == .restAPI ? URL(string: endpoint) : nil,
            headers: existing?.headers ?? [:],
            includedTypes: includedTypes,
            createdAt: existing?.createdAt ?? .now
        )
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
