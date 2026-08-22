import HozzCatalog
import HozzCore
import HozzDeliver
import HozzHealth
import HozzUI
import SwiftUI

/// Chooses which Health types a destination receives.
///
/// This is the one kind of "off" Hozz genuinely knows about. Apple deliberately
/// hides whether a read permission was granted, so an empty type is always
/// ambiguous — but a type the user excluded here is unambiguous, so it can be
/// skipped entirely rather than read and reported as unknown.
///
/// Narrowing the selection also cuts how often iOS wakes the app, which is the
/// single biggest lever on battery for a tool like this.
struct TypePickerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<HealthTypeKey>
    @State private var searchText = ""
    private let onSave: (Set<HealthTypeKey>) -> Void

    private let groups: [(family: HealthTypeFamily, entries: [HealthCatalogEntry])]

    init(
        selection: Set<HealthTypeKey>,
        onSave: @escaping (Set<HealthTypeKey>) -> Void
    ) {
        _selection = State(initialValue: selection)
        self.onSave = onSave

        let exportable = Set(
            HealthKitTypeRegistry.exportableTypes().map(\.catalogEntry.key)
        )
        let entries = HealthTypeCatalog.entries
            .filter { exportable.contains($0.key) }
            .sorted { $0.displayName < $1.displayName }

        self.groups = Dictionary(grouping: entries, by: \.family)
            .map { (family: $0.key, entries: $0.value) }
            .sorted { $0.family.rawValue < $1.family.rawValue }
    }

    var body: some View {
        List {
            Section {
                Toggle(
                    "Everything Hozz can read",
                    isOn: Binding(
                        get: { selection.isEmpty },
                        set: { isOn in
                            selection = isOn ? [] : Set(commonKeys)
                        }
                    )
                )
            } footer: {
                Text(
                    selection.isEmpty
                        ? "Hozz will send every type it has access to."
                        : "\(selection.count) types selected. Fewer types means "
                          + "iOS wakes Hozz less often, which uses less battery."
                )
            }

            if !selection.isEmpty {
                ForEach(filteredGroups, id: \.family) { group in
                    Section(group.family.sectionTitle) {
                        ForEach(group.entries, id: \.key) { entry in
                            Button {
                                toggle(entry.key)
                            } label: {
                                HStack {
                                    Text(entry.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selection.contains(entry.key) {
                                        HozzIconView(.check, size: 18)
                                            .foregroundStyle(HozzPalette.action)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search data types")
        .navigationTitle("Data types")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    onSave(selection)
                    dismiss()
                }
            }
        }
    }

    private var commonKeys: [HealthTypeKey] {
        HealthObserverDefaults.commonTypeIdentifiers.map(HealthTypeKey.init)
    }

    private var filteredGroups: [(family: HealthTypeFamily, entries: [HealthCatalogEntry])] {
        guard !searchText.isEmpty else {
            return groups
        }
        return groups.compactMap { group in
            let matches = group.entries.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
            return matches.isEmpty ? nil : (family: group.family, entries: matches)
        }
    }

    private func toggle(_ key: HealthTypeKey) {
        if selection.contains(key) {
            selection.remove(key)
        } else {
            selection.insert(key)
        }
    }
}

private extension HealthTypeFamily {
    var sectionTitle: String {
        switch self {
        case .quantity: "Measurements"
        case .category: "Events and states"
        case .workout: "Workouts"
        case .correlation: "Correlations"
        case .characteristic: "Characteristics"
        case .clinical: "Clinical"
        case .document: "Documents"
        case .scoredAssessment: "Assessments"
        }
    }
}
