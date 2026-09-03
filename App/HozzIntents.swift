import AppIntents
import Foundation
import HozzHealth

/// Shortcuts and Siri entry points.
///
/// Shortcuts are given roughly ten seconds and a small memory budget, so these
/// deliberately do the smallest useful thing: ask for a sync and report what
/// happened. Anything long-running is left to the background scheduler, which
/// is allowed to checkpoint and resume.
struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Health Data"
    static let description = IntentDescription(
        "Sends new Health data now.",
        categoryName: "Export"
    )
    /// Running in the app rather than an extension keeps one lease over the
    /// store, so a Shortcut can never collide with a foreground export.
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try HozzServices()
        let outcome = try await services.sync.sync(force: true)

        if outcome.waitingForUnlock {
            return .result(
                dialog: "Unlock your iPhone to continue."
            )
        }
        if outcome.deliveredRecords == 0 {
            return .result(dialog: "Already up to date.")
        }
        let plural = outcome.deliveredRecords == 1 ? "record" : "records"
        return .result(
            dialog: "Sent \(outcome.deliveredRecords.formatted()) \(plural)."
        )
    }
}

/// Reports the current state without changing anything.
struct SyncStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Health Sync Status"
    static let description = IntentDescription(
        "Reports the last Health sync.",
        categoryName: "Export"
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try HozzServices()
        let destinations = try await services.delivery.destinations()

        guard !destinations.isEmpty else {
            return .result(
                dialog: "No destination. Nothing is being sent."
            )
        }

        var latest: Date?
        var records = 0
        var needsAttention = false
        for destination in destinations {
            guard let state = try await services.delivery.state(for: destination.id) else {
                continue
            }
            if let success = state.lastSuccessAt,
               success > (latest ?? .distantPast) {
                latest = success
            }
            records += state.deliveredRecords
            if state.state == "needsAttention" {
                needsAttention = true
            }
        }

        if needsAttention {
            return .result(dialog: "A Hozz destination needs attention.")
        }
        guard let latest else {
            return .result(dialog: "No sync has completed yet.")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: latest, relativeTo: .now)
        return .result(
            dialog: "Hozz last synced \(relative), \(records.formatted()) records in total."
        )
    }
}

/// Starts a full historical export.
///
/// This one opens the app on purpose: a complete export takes minutes, far
/// longer than a Shortcut is allowed, and it needs somewhere to show progress.
struct StartFullExportIntent: AppIntent {
    static let title: LocalizedStringResource = "Export All Health Data"
    static let description = IntentDescription(
        "Opens Hozz and exports your Health history.",
        categoryName: "Export"
    )
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct HozzShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: [
                "Sync my Health data with \(.applicationName)",
                "Run \(.applicationName)"
            ],
            shortTitle: "Sync Now",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: SyncStatusIntent(),
            phrases: [
                "Check \(.applicationName) status",
                "When did \(.applicationName) last sync"
            ],
            shortTitle: "Sync Status",
            systemImageName: "checkmark.circle"
        )
    }
}
