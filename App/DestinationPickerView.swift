import HozzDeliver
import HozzUI
import SwiftUI

/// Chooses what kind of destination to add.
///
/// Naming Home Assistant and MQTT separately matters even though one of them is
/// an HTTPS endpoint underneath. A capability nobody can find is not a
/// capability, and "how do I connect this to Home Assistant" is the question
/// people ask most about tools like this.
struct DestinationPickerView: View {
    let model: SyncViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: DestinationPreset?

    var body: some View {
        List {
            Section {
                ForEach(DestinationPreset.allCases) { preset in
                    Button {
                        chosen = preset
                    } label: {
                        HStack(spacing: 14) {
                            Image(preset.iconName)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 26, height: 26)
                                .foregroundStyle(
                                    preset.isRecommended ? HozzPalette.action : .secondary
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(preset.displayName)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if preset.isRecommended {
                                        Text("Easiest")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                HozzPalette.action.opacity(0.15),
                                                in: Capsule()
                                            )
                                            .foregroundStyle(HozzPalette.action)
                                    }
                                }
                                Text(preset.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                            HozzIconView(.chevronRight, size: 14)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Where should your Health data go?")
            } footer: {
                Text(
                    "Hozz has no default destination. Nothing leaves this "
                    + "iPhone until you add one."
                )
            }
        }
        .navigationTitle("Add a destination")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .navigationDestination(item: $chosen) { preset in
            DestinationEditorView(
                model: model,
                destination: nil,
                preset: preset
            )
        }
    }
}
