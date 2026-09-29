import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ActivityView: View {

    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var journal: Journal
    @EnvironmentObject private var pipeline: Pipeline
    @Environment(\.openSettings) private var openSettings

    enum Filter: String, CaseIterable {
        case all = "All"
        case needsYou = "Needs you"
        case held = "Held"
        case cleared = "Cleared"
    }

    @State private var filter: Filter = .all
    /// Which Settings tab opens next; the Privacy tab is where the key goes.
    @AppStorage("settingsTab") private var settingsTab = "general"

    private func openPrivacySettings() {
        settingsTab = "privacy"
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    /// A fresh process, so the keychain is asked again for the journal key.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    @State private var dropTargeted = false
    @State private var showLegend = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            dropZone
            Divider()

            if showLegend {
                LegendStrip()
            } else if journal.entries.isEmpty || (!pipeline.hasAPIKey || activeFolderCount == 0) && journal.visible.isEmpty {
                emptyState
            } else {
                if journal.pendingCount > 0 {
                    pendingBanner
                }
                // The bar stays after "Clear N": it is the only way back to
                // the Cleared filter, where undo lives for dismissed rows.
                filterBar
                Divider().opacity(0.5)
                entryList
            }

            Divider()
            footer
        }
        .frame(width: 420)
        // The whole panel accepts a drop, not just the strip — a 40pt target in a
        // popover you have to open first is not something anyone would use twice.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                    .background(Color.accentColor.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(statusTint)
                    .symbolRenderingMode(.hierarchical)

                Text("Usher")
                    .font(.system(size: 12.5, weight: .semibold))

                Spacer()

                PillToggle(title: "Dry run",
                           symbol: settingsStore.settings.dryRun ? "eye.fill" : "eye.slash",
                           tint: .orange,
                           isOn: Binding(
                               get: { settingsStore.settings.dryRun },
                               set: { settingsStore.settings.dryRun = $0 }
                           ))
                    .help("On: decisions are logged and nothing moves. Turning it off asks before filing the previews above your threshold.")
            }

            // Status and counts on separate lines: with "Catching up · 248 of
            // 281" and three chips on one row, the row was wider than the panel
            // and the popover clipped the right edge off.
            HStack(spacing: 4) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if counts.filed + counts.pending + counts.held > 0 {
                HStack(spacing: 6) {
                    if counts.filed > 0  { Chip(text: "\(counts.filed) filed", tint: .green) }
                    if counts.pending > 0 { Chip(text: "\(counts.pending) waiting", tint: .blue) }
                    if counts.held > 0   { Chip(text: "\(counts.held) held", tint: .purple) }
                    Spacer(minLength: 0)
                }
            }

            if let error = pipeline.lastError {
                // The whole message, and the one thing that fixes it. The box
                // used to cut a 170-character message at two lines and offer
                // nothing to press.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9.5))
                            .padding(.top, 1.5)
                        Text(error)
                            .font(.system(size: 10.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.red)
                    HStack(spacing: 6) {
                        if journal.isLocked {
                            RowButton(title: "Relaunch Usher", symbol: "arrow.clockwise", tint: .red) { Self.relaunch() }
                        } else if !pipeline.hasAPIKey || error.contains("Settings → Privacy") {
                            RowButton(title: "Open Settings", symbol: "gearshape", tint: .red) { openPrivacySettings() }
                            RowButton(title: "Try again", symbol: "arrow.clockwise", tint: .secondary, quiet: true) { pipeline.retryNow() }
                        } else {
                            RowButton(title: "Try again", symbol: "arrow.clockwise", tint: .red) { pipeline.retryNow() }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if !pipeline.policyMovesWaiting.isEmpty {
                // Turning dry run off (or moving a threshold) would move files.
                // A toggle should not do that by surprise.
                let n = pipeline.policyMovesWaiting.count
                VStack(alignment: .leading, spacing: 6) {
                    Text(n == 1 ? "1 previewed file is now above your threshold. File it?"
                                : "\(n) previewed files are now above your threshold. File them?")
                        .font(.system(size: 10.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        RowButton(title: n == 1 ? "File it" : "File \(n)", symbol: "checkmark", tint: .blue, prominent: true) {
                            pipeline.confirmPolicyMoves()
                        }
                        RowButton(title: "Not now", tint: .secondary, quiet: true) { pipeline.declinePolicyMoves() }
                    }
                }
                .foregroundStyle(.blue)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if !pipeline.lastBulkMove.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                    Text("Moved \(pipeline.lastBulkMove.count) files")
                        .font(.system(size: 10.5, weight: .medium))
                    Spacer()
                    RowButton(title: "Undo all", symbol: "arrow.uturn.backward", tint: .green) {
                        pipeline.undoLastBulkMove()
                    }
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// Drop anything here and it gets filed, whether or not it came from a browser
    /// and whether or not it lives in a watched folder.
    private var dropZone: some View {
        HStack(spacing: 7) {
            Image(systemName: dropTargeted ? "tray.and.arrow.down.fill" : "plus.rectangle.on.folder")
                .font(.system(size: 12))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)

            Text(dropTargeted ? "Drop to file it" : "Drop files here to classify them")
                .font(.system(size: 11, weight: dropTargeted ? .semibold : .regular))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)

            Spacer()

            if settingsStore.settings.dryRun {
                Text("preview only")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(dropTargeted ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(
                    dropTargeted ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.13),
                    style: StrokeStyle(lineWidth: 1, dash: dropTargeted ? [] : [3, 2])
                )
        )
        .padding(.horizontal, 13)
        .padding(.bottom, 11)
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            // loadObject is the clean path, but some sources only vend the raw
            // bookmark data, so fall back rather than silently dropping the file.
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in pipeline.acceptDrop([url]) }
                }
            } else {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          url.isFileURL else { return }
                    Task { @MainActor in pipeline.acceptDrop([url]) }
                }
            }
        }
    }

    private var pendingBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10))
            Text(journal.pendingCount == 1 ? "1 file needs a decision" : "\(journal.pendingCount) files need a decision")
                .font(.system(size: 10.5, weight: .medium))
            Spacer()
            if filter != .needsYou {
                Button("Show") { withAnimation(.easeOut(duration: 0.15)) { filter = .needsYou } }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
            }
            if pipeline.approvableCount > 1 {
                Button("Move all \(pipeline.approvableCount)") {
                    withAnimation(.easeOut(duration: 0.15)) { pipeline.approveAll() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Color.blue.opacity(0.14))
                .clipShape(Capsule())
                .help("Approve every waiting proposal at once. Proposals that would create a new folder are left for you to decide one by one.")
            }
        }
        .foregroundStyle(.blue)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(Color.blue.opacity(0.08))
    }

    private var filterBar: some View {
        HStack(spacing: 5) {
            ForEach(Filter.allCases, id: \.self) { option in
                let selected = filter == option
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { filter = option }
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(selected ? Color.primary.opacity(0.08) : .clear)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(filtered.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
    }

    private var entryList: some View {
        let rows = filter == .needsYou ? filtered : Array(filtered.prefix(80))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { entry in
                    EntryRow(entry: entry)
                    Divider().opacity(0.35).padding(.leading, 40)
                }

                if rows.isEmpty {
                    Text(emptyListText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
        }
        .frame(maxHeight: 370)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !pipeline.hasAPIKey || activeFolderCount == 0 {
            // First launch: a checklist that ticks itself, so a new user sees
            // where they are instead of reading prose.
            VStack(alignment: .leading, spacing: 10) {
                Text("Getting started")
                    .font(.system(size: 12, weight: .semibold))
                checklistRow(done: pipeline.hasAPIKey,
                             "API key", pipeline.hasAPIKey ? "Set." : "Usher asks a small classification model where each file belongs. Until there is a key it sends nothing.")
                checklistRow(done: activeFolderCount > 0,
                             "Folders", activeFolderCount > 0
                                ? "Watching \(activeFolderCount)."
                                : "Add Downloads or Desktop in Settings → Folders. macOS asks once for access — allow it.")
                checklistRow(done: !settingsStore.settings.dryRun,
                             "Dry run", settingsStore.settings.dryRun
                                ? "On. Files are decided and logged, never moved. Turn it off with the pill above when the previews look right."
                                : "Off. Files move.")
                HStack(spacing: 6) {
                    if !pipeline.hasAPIKey {
                        RowButton(title: "Open Settings → Privacy", symbol: "key", tint: .blue, prominent: true) { openPrivacySettings() }
                    } else {
                        RowButton(title: "Open Settings → Folders", symbol: "folder", tint: .blue, prominent: true) {
                            settingsTab = "folders"; NSApp.activate(ignoringOtherApps: true); openSettings()
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Nothing filed yet")
                    .font(.system(size: 12, weight: .medium))
                Text(settingsStore.settings.dryRun
                     ? "Dry run is on: Usher will show what it would do and move nothing. Download something, or sweep a folder below."
                     : "Download something, or sweep a watched folder below.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
        }
    }

    private func checklistRow(done: Bool, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(done ? Color.green : Color.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11.5, weight: .medium))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(done ? "done" : "to do"). \(detail)")
    }

    /// What an empty list means depends on which list it is.
    private var emptyListText: String {
        switch filter {
        case .all:      return "All clear. New downloads show up here."
        case .needsYou: return "Nothing is waiting on you."
        case .held:     return "Nothing held."
        case .cleared:  return "Nothing cleared yet."
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(settingsStore.settings.watchFolders.filter(\.enabled)) { folder in
                    Button(folder.displayName) { pipeline.sweep(folder: folder.url) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .rotationEffect(.degrees(pipeline.isBusy ? 360 : 0))
                        .animation(pipeline.isBusy ? .linear(duration: 1.4).repeatForever(autoreverses: false) : .default,
                                   value: pipeline.isBusy)
                    Text(pipeline.isBusy ? "Sweeping…" : "Sweep")
                }
                .padding(.horizontal, 7).padding(.vertical, 3.5)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(pipeline.isBusy)
            .help("Classify files already sitting in a watched folder")

            FooterButton(title: showLegend ? "Back to the list" : "Guide — what the icons mean",
                         symbol: showLegend ? "arrow.left" : "questionmark.circle",
                         iconOnly: true) {
                withAnimation(.easeOut(duration: 0.15)) { showLegend.toggle() }
            }

            FooterButton(title: "Settings", symbol: "gearshape", iconOnly: true) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Spacer(minLength: 6)

            if journal.clearableCount > 0 {
                FooterButton(title: "Clear \(journal.clearableCount)", symbol: "checkmark.circle") {
                    withAnimation(.easeOut(duration: 0.15)) { journal.clearDone() }
                }
                .help("Clear handled rows (⌘K). Nothing is deleted; Undo stays under Cleared.")
                .keyboardShortcut("k", modifiers: .command)
            }

            FooterButton(title: "Quit Usher", symbol: "power", iconOnly: true) {
                NSApplication.shared.terminate(nil)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Derived

    private var filtered: [JournalEntry] {
        switch filter {
        case .all:
            return journal.visible
        case .needsYou:
            return journal.visible.filter { $0.outcome == .pendingApproval }
        case .held:
            return journal.visible.filter { $0.outcome == .heldSensitive || $0.outcome == .neverClassified }
        case .cleared:
            // Where undo lives for something already dismissed.
            return journal.entries.filter { $0.cleared }
        }
    }

    /// Counted over what the panel shows. Counting the whole journal meant
    /// "101 filed" stayed in the header forever after everything was cleared,
    /// with nothing underneath it.
    private var counts: (filed: Int, pending: Int, held: Int) {
        var filed = 0, pending = 0, held = 0
        for entry in journal.visible {
            switch entry.outcome {
            case .moved where !entry.undone: filed += 1
            case .pendingApproval:           pending += 1
            case .heldSensitive, .neverClassified: held += 1
            default:                         break
            }
        }
        return (filed, pending, held)
    }

    private var activeFolderCount: Int {
        settingsStore.settings.watchFolders.filter { $0.enabled && $0.exists }.count
    }

    private var statusTint: Color {
        if journal.isLocked || pipeline.apiUnavailable { return .red }
        guard pipeline.isRunning else { return .secondary }
        if journal.pendingCount > 0 { return .blue }
        return settingsStore.settings.dryRun ? .orange : .green
    }

    private var statusText: String {
        if journal.isLocked { return "Locked — nothing is being filed" }
        if !pipeline.hasAPIKey { return "Waiting for an API key" }
        if pipeline.apiUnavailable { return "Can't reach the classification service" }
        guard pipeline.isRunning else { return "Paused" }
        if let progress = pipeline.catchUpProgress {
            return "Catching up · \(progress.done) of \(progress.total)"
        }
        let n = activeFolderCount
        return n == 0
            ? "No folders watched — add one in Settings"
            : "Watching \(n) folder\(n == 1 ? "" : "s")"
    }
}

// MARK: - Footer button

private struct FooterButton: View {
    let title: String
    let symbol: String
    /// Icon only. Six labelled items do not fit 420pt: "Settings" wrapped to
    /// "Setting/s" and "Clear 299" split across two lines. Same mistake the
    /// row buttons had, one component over.
    var iconOnly: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: iconOnly ? 12 : 10))
                if !iconOnly {
                    Text(title).lineLimit(1)
                }
            }
            .padding(.horizontal, iconOnly ? 6 : 7)
            .padding(.vertical, 3.5)
            .frame(height: 20)
            .background(hovering ? Color.primary.opacity(0.07) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        // Nothing in the footer ever wraps: it keeps its width and the row
        // runs out of items before it runs out of pixels.
        .fixedSize()
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Row

private struct EntryRow: View {

    let entry: JournalEntry
    @EnvironmentObject private var pipeline: Pipeline
    @EnvironmentObject private var journal: Journal
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var hovering = false
    @State private var confirmTrash = false

    private var glyph: (name: String, tint: Color) {
        // A directory has no extension to read, so "folder of 270 files" used
        // to sit next to a document icon.
        if entry.isDirectory { return ("folder.fill", .secondary) }
        return FileGlyph.symbol(for: (entry.filename as NSString).pathExtension)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.undone ? "arrow.uturn.backward" : glyph.name)
                .font(.system(size: 14))
                .foregroundStyle(glyph.tint.opacity(entry.undone ? 0.4 : 0.85))
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(entry.filename)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .strikethrough(entry.undone, color: .secondary)

                    // Said once. A moved row says it with a green arrow and a
                    // folder; a pending row with its blue tint and a Move
                    // button; the rest need the word.
                    if showsChip {
                        Chip(text: entry.outcome.shortLabel, tint: entry.outcome.tint, compact: true)
                    }
                    if entry.createsFolder, !entry.undone {
                        Chip(text: "new folder", tint: .orange, compact: true)
                    }
                }

                destinationLine

                if showsReason, let reason = entry.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if entry.outcome == .pendingApproval, let runners = runnersUp, !runners.isEmpty {
                    Text("also considered: " + runners)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                if let probability = entry.routeProbability, !entry.undone, entry.outcome.showsConfidence {
                    HStack(spacing: 5) {
                        Text(String(format: "%.0f%%", probability * 100))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        ConfidenceBar(probability: probability,
                                      askThreshold: settingsStore.settings.askThreshold,
                                      autoThreshold: settingsStore.settings.autoMoveThreshold)
                    }
                }
                actions
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(rowBackground)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.13), value: hovering)
        .onHover { hovering = $0 }
        .help([entry.reason, entry.outcome.explanation].compactMap { $0 }.joined(separator: "\n\n"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.filename), \(entry.undone ? "put back" : entry.outcome.shortLabel)")
        // Show and Trash only appear on hover, which VoiceOver never does.
        .accessibilityAction(named: "Show in Finder") { reveal() }
        .accessibilityAction(named: "Move to Trash") { pipeline.trash(entry) }
        .accessibilityAction(named: entry.canUndo ? "Undo" : "Move") {
            if entry.canUndo { pipeline.undo(entry) }
            else if entry.outcome == .pendingApproval { pipeline.approve(entry) }
        }
        .contextMenu {
            Button("Show in Finder") { reveal() }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.currentPath, forType: .string)
            }
            if entry.canUndo { Button("Undo") { pipeline.undo(entry) } }
            if entry.outcome == .pendingApproval {
                Button("Move it") { pipeline.approve(entry) }
                Button("Leave it") { journal.decline(entry) }
            }
            Divider()
            Button("Move to Trash") { pipeline.trash(entry) }
                .disabled(entry.outcome == .trashed || entry.outcome == .neverClassified)
        }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.currentPath)])
    }

    /// The outcome in words, where the row does not already say it another way.
    private var showsChip: Bool {
        if entry.undone { return false }
        return entry.outcome != .moved && entry.outcome != .pendingApproval
    }

    /// Duplicate, unsorted, unsure and failed all carry a reason the person
    /// would act on ("same bytes as X", "no route matched") and used to hide it.
    private var showsReason: Bool {
        switch entry.outcome {
        case .pendingApproval, .heldSensitive, .duplicate, .unsorted, .lowConfidence, .failed, .neverClassified, .trashed:
            return true
        case .moved, .dryRun, .alreadyFiled:
            return false
        }
    }

    /// The next two routes Jev weighed, so "Move" is a choice and not a gamble.
    private var runnersUp: String? {
        guard let alts = entry.alternatives else { return nil }
        let chosen = entry.routeKey
        let rest = alts.filter { $0.key != chosen && $0.key != RouteTable.unsortedKey }
            .sorted { $0.value > $1.value }
            .prefix(2)
            .map { "\($0.key) \(Int(($0.value * 100).rounded()))%" }
        return rest.isEmpty ? nil : rest.joined(separator: ", ")
    }

    @ViewBuilder
    private var destinationLine: some View {
        if entry.undone {
            Text(entry.outcome == .trashed ? "back from the Trash" : "put back")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else if let path = entry.finalPath ?? entry.proposedPath {
            HStack(spacing: 3) {
                Image(systemName: entry.outcome == .moved ? "arrow.turn.down.right" : "arrow.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(entry.outcome.tint)
                Text(shortPath(path))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 10))
            .onTapGesture { reveal() }
        }
        // No `else`: a row with no destination says why on the reason line.
        // "Held / held / filename matched \"rechnung\"" was one fact three times.
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            // A decision waiting on you stays visible; everything else is hover-only.
            // At most one labelled action per row. Three labelled pills left
            // the filename 190pt of a 420pt panel and wrapped "Show" to "Sho/w".
            if entry.outcome == .pendingApproval {
                RowButton(title: "Leave", symbol: "xmark", tint: .secondary, quiet: true) {
                    withAnimation(.easeOut(duration: 0.15)) { journal.decline(entry) }
                }
                .help("Keep the file where it is and stop asking")
                RowButton(title: "Move", symbol: "checkmark",
                          tint: .blue, prominent: true) {
                    pipeline.approve(entry)
                }
                .help("File it where the row says")
            } else if entry.outcome == .failed, !entry.cleared, entry.routeKey != "trash" {
                RowButton(title: "Retry", symbol: "arrow.clockwise", tint: .orange) {
                    pipeline.retry(entry)
                }
                .help("Run this file through again")
            } else if entry.canUndo {
                // Readable at rest, loud only on hover: an undo you cannot see
                // is an undo you do not know you have.
                RowButton(title: "Undo", symbol: "arrow.uturn.backward",
                          tint: .secondary, quiet: true) {
                    pipeline.undo(entry)
                }
                .help("Put it back where it came from")
            }

            RowButton(symbol: "folder", tint: .secondary, quiet: true) { reveal() }
                .help("Show in Finder")
                .accessibilityLabel("Show \(entry.filename) in Finder")
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)

            // Reviewing a row and deciding the file is junk is common enough
            // to deserve a button. Trash, so Undo brings it straight back.
            if entry.outcome != .trashed, !entry.undone, entry.outcome != .neverClassified {
                // A whole folder takes a second click: the first one arms it.
                RowButton(title: confirmTrash ? "Trash folder?" : nil, symbol: "trash", tint: .red, quiet: !confirmTrash) {
                    if entry.isDirectory && !confirmTrash {
                        confirmTrash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confirmTrash = false }
                        return
                    }
                    confirmTrash = false
                    withAnimation(.easeOut(duration: 0.15)) { pipeline.trash(entry) }
                }
                .help(entry.isDirectory ? "Move the whole folder to the Trash — click twice. Undo puts it back."
                                        : "Move to the Trash. Undo puts it back.")
                .accessibilityLabel("Move \(entry.filename) to the Trash")
                .opacity(hovering || confirmTrash ? 1 : 0)
                .allowsHitTesting(hovering || confirmTrash)
            }
        }
        // Fading in place rather than inserting: adding the buttons to the layout
        // on hover reflows the row and nudges the filename sideways under the
        // cursor, which reads as a glitch.
        .animation(.easeOut(duration: 0.13), value: hovering)
    }

    private var rowBackground: Color {
        if entry.outcome == .pendingApproval { return Color.blue.opacity(0.05) }
        return hovering ? Color.primary.opacity(0.04) : .clear
    }

    private func shortPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent().lastPathComponent
        let renamed = url.lastPathComponent != entry.filename
        return renamed ? "\(folder)/\(url.lastPathComponent)" : folder
    }
}
