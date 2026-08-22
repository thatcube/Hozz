import SwiftUI

@main
struct HozzApp: App {
    init() {
        // Registration has to happen before the app finishes launching, which
        // is why it is here rather than in a task modifier.
        BackgroundExportScheduler.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(HozzPalette.action)
        }
    }
}
