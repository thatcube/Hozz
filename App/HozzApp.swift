import HozzUI
import SwiftUI

@main
struct HozzApp: App {
    init() {
        // Registration has to happen before the app finishes launching, which
        // is why it is here rather than in a task modifier.
        BackgroundExportScheduler.register()
        // Ask for the first sync slot straight away, so automatic export starts
        // working before the user opens the app a second time.
        BackgroundExportScheduler.scheduleRefresh(after: 60)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(HozzPalette.blue)
        }
    }
}
