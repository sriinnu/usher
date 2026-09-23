import AppKit
import Combine

/// Owns the menubar item and receives files dropped on the app itself — on its
/// icon in Finder, or on a Dock alias.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Built on the main actor at launch, not at init: NSApplicationDelegateAdaptor
    // constructs the delegate from a nonisolated context.
    private var statusItem: StatusItemController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let state = AppState.shared

            let statusItem = StatusItemController()
            self.statusItem = statusItem
            statusItem.install()
            // Watching starts at launch, not when a panel is first opened.
            state.start()

            // Keep the icon's colour in step with dry run and pending decisions.
            state.journal.objectWillChange
                .merge(with: state.settingsStore.objectWillChange)
                .merge(with: state.pipeline.objectWillChange)
                .receive(on: RunLoop.main)
                .sink { [weak statusItem] in statusItem?.refreshIcon() }
                .store(in: &cancellables)

            drainPending()
        }
    }

    // MARK: - Files opened via Finder or the Dock

    /// Dropping on the app can launch it, so files may arrive before the pipeline
    /// is ready. Anything early is held and drained at launch.
    private static var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }

        MainActor.assumeIsolated {
            guard AppState.shared.pipeline.isRunning else {
                Self.pending.append(contentsOf: files)
                return
            }
            AppState.shared.pipeline.acceptDrop(files)
        }
    }

    @MainActor
    private func drainPending() {
        guard !Self.pending.isEmpty else { return }
        let queued = Self.pending
        Self.pending.removeAll()
        AppState.shared.pipeline.acceptDrop(queued)
    }
}
