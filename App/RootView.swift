import HozzHealth
import HozzUI
import SwiftUI

/// Which tab a debug build opens on.
///
/// The simulator cannot be tapped from a script, so without this only the
/// first tab is ever seen outside Brandon's hands, and "it builds" stands in
/// for "it looks right" on every other screen. Release builds always open on
/// the first tab.
enum HozzTabLaunch {
    static var initialTab: Int {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard
            let index = arguments.firstIndex(of: "-HozzTab"),
            index + 1 < arguments.count,
            let value = Int(arguments[index + 1])
        else {
            return 0
        }
        return value
        #else
        return 0
        #endif
    }
}

struct RootView: View {

    @State private var model: ExportViewModel
    @State private var syncModel = SyncViewModel()
    /// Which tab is showing. Held rather than left to SwiftUI so a debug build
    /// can be launched straight onto any of them: the simulator cannot be
    /// tapped from a script, and a screen nobody can open is a screen nobody
    /// looks at.
    @State private var tab = HozzTabLaunch.initialTab
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
        TabView(selection: $tab) {
            NavigationStack {
                DashboardView()
            }
            .tag(0)
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
            .tag(1)
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
            .tag(2)
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
            .tag(3)
            .tabItem {
                Label {
                    Text("About")
                } icon: {
                    Image(HozzIcon.infoCircle.rawValue).renderingMode(.template)
                }
            }
        }
        .tint(HozzPalette.blue)
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

enum HozzLinks {
    static let source = URL(string: "https://github.com/thatcube/hozz")!
    static let sponsors = URL(string: "https://github.com/sponsors/thatcube")!
    static let developer = URL(string: "https://github.com/thatcube")!
}
