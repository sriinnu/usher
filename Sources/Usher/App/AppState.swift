import Foundation

/// Single owner of the app's long-lived objects.
///
/// The status item is built in AppKit and the panel in SwiftUI, and both need the
/// same pipeline, so neither can own it. Creating them here keeps one instance and
/// lets the watcher start at launch rather than when a window first appears.
@MainActor
final class AppState {

    static let shared = AppState()

    let settingsStore: SettingsStore
    let journal: Journal
    let pipeline: Pipeline

    private init() {
        let settingsStore = SettingsStore()
        if let key = LogCipher.key() { LogCipher.migrateAll(key: key) }
        let journal = Journal()
        self.settingsStore = settingsStore
        self.journal = journal
        self.pipeline = Pipeline(settingsStore: settingsStore, journal: journal)
    }

    func start() {
        if !pipeline.isRunning { pipeline.start() }
    }
}
