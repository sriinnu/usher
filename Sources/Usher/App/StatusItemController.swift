import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Replaces SwiftUI's `MenuBarExtra`, which cannot do either of the two things
/// that matter here:
///
///   1. Its popover closes as soon as another app activates. Clicking the icon and
///      then switching to Finder to fetch a file hides the panel before the drag
///      even starts, so dropping onto it is impossible.
///   2. Its status item is not reachable, so the icon itself cannot accept a drag.
///
/// A hand-rolled `NSStatusItem` fixes both: the icon is a drop target, and the
/// popover uses `.applicationDefined` so it survives switching to Finder.
@MainActor
final class StatusItemController: NSObject {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    /// Drives the pulse while the pipeline is busy; nil when idle.
    private var pulse: Timer?
    private var phase = 0
    /// Events inside Usher — Escape, and clicks on our own windows.
    private var localMonitor: Any?
    /// Clicks in *other* apps. Required because Usher is LSUIElement and never
    /// becomes active, so AppKit's own `.transient` dismissal never fires: it
    /// closes a popover when the owning app sees an outside click, and Usher
    /// never sees one. Without this, unpinning appeared to do nothing at all.
    private var globalMonitor: Any?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        button.image = MenuBarIcon.image(pending: 0, dryRun: true, running: true)
        button.target = self
        button.action = #selector(togglePanel)
        button.toolTip = "Usher — drop files here to file them"

        // The button is an NSView, so a transparent overlay can take the drag
        // without interfering with the click.
        let dropView = IconDropView(frame: button.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.onDrop = { [weak self] urls in
            Task { @MainActor in
                AppState.shared.pipeline.acceptDrop(urls)
                self?.flashAccepted()
            }
        }
        dropView.onClick = { [weak self] in
            Task { @MainActor in self?.togglePanel() }
        }
        button.addSubview(dropView)

        statusItem = item
        refreshIcon()
    }

    /// Keeps the icon's tint in step with state: grey paused, orange dry run,
    /// green live, blue when something needs a decision.
    func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let state = AppState.shared
        let busy = state.pipeline.isBusy
        let locked = state.journal.isLocked
        let alert = locked || state.pipeline.apiUnavailable
        button.image = MenuBarIcon.image(
            pending: state.journal.pendingCount,
            dryRun: state.settingsStore.settings.dryRun,
            running: state.pipeline.isRunning,
            busy: busy, phase: phase, alert: alert
        )
        let pending = state.journal.pendingCount
        button.setAccessibilityLabel(
            locked ? "Usher, locked" :
            alert ? "Usher, can't reach the classification service" :
            busy ? "Usher, working" :
            pending == 1 ? "Usher, 1 file needs a decision" :
            pending > 1 ? "Usher, \(pending) files need a decision" :
            !state.pipeline.isRunning ? "Usher, paused" :
            state.settingsStore.settings.dryRun ? "Usher, dry run" : "Usher, watching")
        if alert {
            button.toolTip = "Usher — " + (state.pipeline.lastError ?? "needs attention")
        } else if let p = state.pipeline.catchUpProgress {
            button.toolTip = "Usher — catching up, \(p.done) of \(p.total)"
        } else if busy {
            button.toolTip = "Usher — filing \(state.pipeline.activeCount) file\(state.pipeline.activeCount == 1 ? "" : "s")"
        } else {
            button.toolTip = "Usher — drop files here to file them"
        }

        // A visible sign that something is happening, without a spinner in the
        // menubar: the glyph breathes once a second while busy. It used to
        // strobe at 0.55s / 45% for the whole of a 281-file pass.
        if busy, pulse == nil {
            pulse = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.phase += 1
                    self.refreshIcon()
                }
            }
        } else if !busy, let timer = pulse {
            timer.invalidate(); pulse = nil; phase = 0
        }
    }

    private func flashAccepted() {
        guard let button = statusItem?.button else { return }
        let original = button.image
        // A green check, not the blue "something needs you" glyph the drop
        // used to borrow — those mean opposite things.
        let config = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .medium)
            .applying(.init(paletteColors: [.systemGreen]))
        if let check = NSImage(systemSymbolName: "checkmark.circle.fill",
                               accessibilityDescription: "Accepted")?.withSymbolConfiguration(config) {
            check.isTemplate = false
            button.image = check
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            button.image = original
            self?.refreshIcon()
        }
    }

    // MARK: - Panel

    @objc private func togglePanel() {
        if let popover, popover.isShown {
            close()
        } else {
            open()
        }
    }

    private func open() {
        guard let button = statusItem?.button else { return }

        let pinned = AppState.shared.settingsStore.settings.keepPanelOpen

        let popover = NSPopover()
        // Always .applicationDefined, so dismissal is entirely ours. Handing the
        // unpinned case to AppKit's .transient does not work for a menubar-only
        // app, and produces a toggle that silently does nothing.
        popover.behavior = .applicationDefined
        popover.animates = true

        let state = AppState.shared
        let root = ActivityView()
            .environmentObject(state.settingsStore)
            .environmentObject(state.journal)
            .environmentObject(state.pipeline)
        let hosting = NSHostingController(rootView: root)
        // Track SwiftUI's preferred size; without this the popover keeps its
        // first guess and clips whatever the content grew into.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover

        // Escape always closes, pinned or not.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Escape
            self?.close()
            return nil
        }

        // Unpinned: any click in another app dismisses it, which is what the
        // standard menubar behaviour looks like from the outside.
        if !pinned {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
        }
    }

    private func close() {
        popover?.performClose(nil)
        popover = nil
        for monitor in [localMonitor, globalMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        localMonitor = nil
        globalMonitor = nil
    }
}

/// Transparent overlay on the status item button that accepts file drags.
private final class IconDropView: NSView {

    var onDrop: (([URL]) -> Void)?
    private var highlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty else {
            return false
        }
        onDrop?(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2),
                     xRadius: 4, yRadius: 4).fill()
    }

    /// The overlay sits above the button and must keep hit testing enabled, or
    /// AppKit will not find it as a drag destination. That means it also swallows
    /// the click, so the click is forwarded explicitly.
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }
}
