import SwiftUI

/// The menubar item is built in AppKit (see StatusItemController) because
/// SwiftUI's MenuBarExtra cannot accept a drag on its icon and hides its panel
/// the moment another app activates. SwiftUI still owns the Settings window.
struct UsherApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(AppState.shared.settingsStore)
                .environmentObject(AppState.shared.pipeline)
        }
    }
}
