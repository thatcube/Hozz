import Charts
import SwiftUI
import HozzUI
import HozzReceive
import os

@main
struct HozzMacApp: App {
    @State private var services: MacServices?
    @State private var startupError: String?

    var body: some Scene {
        // A single `Window` rather than a `WindowGroup`. Hozz has one thing to
        // show, and a group can be restored with zero windows — which, with no
        // New Window command, left the app running and permanently unreachable.
        Window("Hozz", id: "main") {
            Group {
                if let services {
                    RootView(services: services)
                } else if let startupError {
                    StartupFailureView(message: startupError)
                } else {
                    ProgressView("Starting Hozz…")
                        .task { await bootstrap() }
                }
            }
            .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1000, height: 640)
    }

    private static let log = Logger(
        subsystem: "com.thatcube.Hozz",
        category: "mac"
    )

    private func bootstrap() async {
        do {
            let services = MacServices()
            self.services = services
            await services.start()
        } catch {
            // Logged as well as shown: a startup failure the user reports as
            // "it just doesn't work" is otherwise impossible to diagnose.
            Self.log.error(
                "Hozz could not start: \(error.localizedDescription, privacy: .public)"
            )
            startupError = error.localizedDescription
        }
    }
}

private struct StartupFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Hozz could not start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
    }
}

struct RootView: View {
    let services: MacServices
    @State private var selection: Section = .connect

    enum Section: String, CaseIterable, Identifiable {
        case connect = "Connect"
        case data = "Data"
        case assistant = "Assistant"
        case activity = "Activity"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .connect: "antenna.radiowaves.left.and.right"
            case .data: "chart.xyaxis.line"
            case .assistant: "sparkles"
            case .activity: "list.bullet.rectangle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection {
            case .connect:
                ConnectView(services: services)
            case .data:
                DataView(services: services)
            case .assistant:
                AssistantView(services: services)
            case .activity:
                ActivityView(services: services)
            }
        }
        // The website's wash, behind the whole window rather than on each pane,
        // so the panes keep their own material and only the light changes.
        .background(HozzPalette.surfaceWash)
    }
}
