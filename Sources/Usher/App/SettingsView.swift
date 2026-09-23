import SwiftUI
import AppKit

/// One source of truth for the window's rhythm. The three tabs previously used
/// 12, 16 and 15pt section gaps, which is the kind of drift nobody notices while
/// writing a view and everybody notices side by side.
enum Layout {
    static let padding: CGFloat = 18
    static let section: CGFloat = 16
    static let withinSection: CGFloat = 8
}

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            identityHeader
            Divider()
            tabs
        }
        .frame(width: 580, height: 500)
    }

    /// The app's own icon, read from the bundle rather than duplicated as an asset,
    /// so it can never drift out of step with what Finder and the Dock show.
    private var identityHeader: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 1) {
                Text("Usher")
                    .font(.system(size: 15, weight: .semibold))
                Text("Files each download where it belongs")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("Version \(Self.version)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(settingsStore.settings.model)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The panel sets this to "privacy" when the fix is an API key, so
    /// "Open Settings" lands where the key goes.
    @AppStorage("settingsTab") private var tab = "general"

    private var tabs: some View {
        TabView(selection: $tab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape.fill") }.tag("general")
            FoldersTab()
                .tabItem { Label("Folders", systemImage: "folder.fill") }.tag("folders")
            RoutingTab()
                .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }.tag("routing")
            PrivacyTab()
                .tabItem { Label("Privacy", systemImage: "lock.fill") }.tag("privacy")
            GuideTab()
                .tabItem { Label("Guide", systemImage: "questionmark.circle.fill") }.tag("guide")
        }
    }
}

/// Shared section wrapper so the three tabs read as one design.
private struct Section<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.withinSection) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.4)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
    }
}


// MARK: - General

struct GeneralTab: View {

    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.section) {
                Section(title: "Menubar panel") {
                    Toggle(isOn: Binding(
                        get: { settingsStore.settings.keepPanelOpen },
                        set: { settingsStore.settings.keepPanelOpen = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pin the panel open")
                                .font(.system(size: 11.5))
                            Text("Stays open when you switch to Finder, so you can drag files in. Dropping onto the menubar icon works either way.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.checkbox)

                }

                Divider()

                Section(title: "Filing") {
                    Toggle(isOn: Binding(
                        get: { settingsStore.settings.dryRun },
                        set: { settingsStore.settings.dryRun = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dry run — decide but never move")
                                .font(.system(size: 11.5))
                            Text("Everything is classified and logged; nothing is moved.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.checkbox)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Duplicates go to")
                                .font(.system(size: 11))
                            TextField("~/Downloads/Duplicates", text: Binding(
                                get: { settingsStore.settings.duplicatesFolder },
                                set: { settingsStore.settings.duplicatesFolder = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 230)
                            Button("Choose…") { chooseDuplicatesFolder() }
                            Spacer()
                        }
                        Text("A file whose bytes already exist at its destination is set aside here instead of being filed twice.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                Section(title: "Model",
                        subtitle: "Jev is the small classification model at api.typesafe.ai that decides where each file goes. It sees the filename and a short excerpt, never the file.") {
                    HStack(spacing: 8) {
                        TextField("jev-latest", text: Binding(
                            get: { settingsStore.settings.model },
                            set: { settingsStore.settings.model = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        Text("jev-latest tracks the newest release")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
            }
            .padding(Layout.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseDuplicatesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use for duplicates"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settingsStore.settings.duplicatesFolder = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Folders

struct FoldersTab: View {

    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var selection: WatchFolder.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.section) {
                Section(title: "Watched folders",
                        subtitle: "New files appearing in these get classified. Each row also says where its files are filed.") {
                    // Scrolls: fourteen folders overflowed a fixed-height window
                    // and the last rows were simply not there.
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(settingsStore.settings.watchFolders.enumerated()), id: \.element.id) { index, folder in
                                FolderRow(folder: folder, selected: selection == folder.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selection = folder.id }
                                if index < settingsStore.settings.watchFolders.count - 1 {
                                    Divider().opacity(0.4).padding(.leading, 38)
                                }
                            }

                            if settingsStore.settings.watchFolders.isEmpty {
                                Text("No folders watched yet")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 26)
                            }
                        }
                    }
                    .frame(maxHeight: 270)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                    )
                }

                HStack(spacing: 8) {
                    Button { addFolder() } label: {
                        Label("Add Folder…", systemImage: "plus")
                    }
                    .controlSize(.regular)

                    Button { removeSelected() } label: {
                        Label("Remove", systemImage: "minus")
                    }
                    .disabled(selection == nil)
                    .keyboardShortcut(.delete, modifiers: [])

                    Spacer()

                    if !suggestions.isEmpty {
                        Menu {
                            ForEach(suggestions, id: \.path) { suggestion in
                                Button {
                                    settingsStore.addFolder(URL(fileURLWithPath: suggestion.path))
                                } label: {
                                    Label(suggestion.name, systemImage: suggestion.symbol)
                                }
                            }
                        } label: {
                            Label("Common folders", systemImage: "folder.badge.plus")
                        }
                        .fixedSize()
                    }
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("macOS asks permission the first time Desktop, Documents or Downloads is read. If a folder never picks anything up, add it again through Add Folder…, which grants access directly.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

        }
        .padding(Layout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var suggestions: [(name: String, path: String, symbol: String)] {
        let home = NSHomeDirectory()
        return [
            ("Desktop", "\(home)/Desktop", "menubar.dock.rectangle"),
            ("Downloads", "\(home)/Downloads", "arrow.down.circle"),
            ("Documents", "\(home)/Documents", "doc"),
            ("Pictures", "\(home)/Pictures", "photo")
        ].filter { candidate in
            !settingsStore.settings.watchFolders.contains { $0.url.path == candidate.1 }
        }
    }

    private func removeSelected() {
        guard let selection,
              let folder = settingsStore.settings.watchFolders.first(where: { $0.id == selection })
        else { return }
        settingsStore.removeFolder(folder)
        self.selection = nil
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "Choose folders to watch for new downloads"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { settingsStore.addFolder(url) }
    }
}

private struct FolderRow: View {

    let folder: WatchFolder
    let selected: Bool
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Watch \(folder.displayName)", isOn: Binding(
                get: { folder.enabled },
                set: { _ in settingsStore.toggleEnabled(folder) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help(folder.enabled ? "Watching" : "Paused")

            Image(systemName: folder.exists ? "folder.fill" : "folder.badge.questionmark")
                .font(.system(size: 13))
                .foregroundStyle(folder.exists
                                 ? (folder.enabled ? Color.accentColor : .secondary)
                                 : .red)
                .frame(width: 17)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(folder.displayName)
                        .font(.system(size: 12, weight: .medium))
                    if !folder.exists {
                        Chip(text: "missing", tint: .red)
                    }
                }
                Text(abbreviated)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            Toggle(isOn: Binding(
                get: { folder.recursive },
                set: { _ in settingsStore.toggleRecursive(folder) }
            )) {
                Text("Subfolders").font(.system(size: 10))
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("Also watch subfolders of \(folder.displayName)")
            .help("Also classify files that appear inside subfolders")

            // Where this folder's files go. Default is the shared root (iCloud);
            // an explicit root confines destinations to it — a Drive folder that
            // files back into Drive, never across a library boundary. The
            // current choice carries a checkmark, like any picker.
            Menu {
                rootChoice("Default (\(defaultRootName))", nil)
                rootChoice("Inside this folder", folder.url.path)
                if let library = libraryRoot(of: folder.url), library.path != folder.url.path {
                    rootChoice("This drive: \(library.lastPathComponent)", library.path)
                }
                if let custom = folder.destinationRoot, !isPreset(custom) {
                    rootChoice(URL(fileURLWithPath: custom).lastPathComponent, custom)
                }
                Divider()
                Button("Choose…") { chooseRoot() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 8, weight: .bold))
                    Text(rootLabel).font(.system(size: 10)).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Destination for \(folder.displayName): \(rootLabel)")
            .help("Where files found in this folder are filed. Explicit roots never cross into another drive.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            selected ? Color.accentColor.opacity(0.1)
                     : (hovering ? Color.primary.opacity(0.05) : .clear)
        )
        .opacity(folder.enabled ? 1 : 0.55)
        .animation(.easeOut(duration: 0.13), value: hovering)
        .onHover { hovering = $0 }
    }

    private var abbreviated: String {
        folder.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var rootLabel: String {
        guard let r = folder.destinationRoot else { return "into \(defaultRootName)" }
        return "into " + URL(fileURLWithPath: (r as NSString).expandingTildeInPath).lastPathComponent
    }

    /// "iCloud Drive" for the CloudDocs container, else whatever the default
    /// root's folder is called. Hard-coding "iCloud" lied once the default moved.
    private var defaultRootName: String {
        let root = (settingsStore.settings.defaultDestinationRoot as NSString).expandingTildeInPath
        return root.hasSuffix("com~apple~CloudDocs") ? "iCloud Drive" : URL(fileURLWithPath: root).lastPathComponent
    }

    private func rootChoice(_ title: String, _ value: String?) -> some View {
        let current = folder.destinationRoot.map { ($0 as NSString).expandingTildeInPath }
        let target = value.map { ($0 as NSString).expandingTildeInPath }
        return Button {
            settingsStore.setDestinationRoot(folder, value)
        } label: {
            if current == target { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func isPreset(_ root: String) -> Bool {
        let expanded = (root as NSString).expandingTildeInPath
        return expanded == folder.url.path || expanded == libraryRoot(of: folder.url)?.path
    }

    /// The cloud library a path lives in, if any: a CloudStorage provider root
    /// (Google Drive, OneDrive, Dropbox) or iCloud Drive.
    private func libraryRoot(of url: URL) -> URL? {
        let parts = url.pathComponents
        if let i = parts.firstIndex(of: "CloudStorage"), i + 1 < parts.count {
            return URL(fileURLWithPath: parts[...(i + 1)].joined(separator: "/").replacingOccurrences(of: "//", with: "/"))
        }
        if let i = parts.firstIndex(of: "com~apple~CloudDocs") {
            return URL(fileURLWithPath: parts[...i].joined(separator: "/").replacingOccurrences(of: "//", with: "/"))
        }
        return nil
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as root"
        panel.message = "Files from \(folder.displayName) will be filed only inside this folder"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settingsStore.setDestinationRoot(folder, url.path)
    }
}

// MARK: - Routing

struct RoutingTab: View {

    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var pipeline: Pipeline

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.section) {
                Section(title: "Destinations",
                        subtitle: "The description of each folder is what the model actually reads — it matters far more than the folder name. {root} is each watched folder's destination root.") {
                    HStack(spacing: 8) {
                        countBadge(symbol: "arrow.triangle.branch",
                                   text: "\(pipeline.routes.leaves.count + pipeline.routes.scans.count) destinations")
                        Spacer()
                        Button("Edit") { NSWorkspace.shared.open(Paths.routes) }
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([Paths.routes]) }
                        Button("Reload") { pipeline.reloadRoutes() }
                    }

                    if let error = pipeline.routes.loadError {
                        loadError(error)
                    } else if !pipeline.routes.roots.isEmpty {
                        RouteTree(roots: pipeline.routes.roots)
                    }
                }

                Divider()

                Section(title: "Local rules",
                        subtitle: "Files matching a rule are filed by code and never sent to the API. First match wins.") {
                    HStack(spacing: 8) {
                        countBadge(symbol: "bolt.shield", text: "\(pipeline.rules.count) rule\(pipeline.rules.count == 1 ? "" : "s") active")
                        Spacer()
                        Button("Edit") { NSWorkspace.shared.open(Paths.rules) }
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([Paths.rules]) }
                    }
                    if let error = pipeline.rulesLoadError {
                        loadError(error)
                    } else if !pipeline.rules.isEmpty {
                        Text(pipeline.rules.map(\.name).joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }

                Divider()

                Section(title: "Thresholds",
                        subtitle: "How sure the model has to be before Usher acts on its own. Changing these never re-sends a file; Usher asks before filing anything that crosses a line.") {
                    ThresholdBand(
                        ask: Binding(
                            get: { settingsStore.settings.askThreshold },
                            set: { settingsStore.settings.askThreshold = $0 }
                        ),
                        auto: Binding(
                            get: { settingsStore.settings.autoMoveThreshold },
                            set: { settingsStore.settings.autoMoveThreshold = $0 }
                        )
                    )
                }

            }
            .padding(Layout.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A hand edit in the JSON is picked up when you come back to the app —
        // "Reload" used to be the only way, and nobody remembered it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            pipeline.reloadRoutes()
        }
    }

    private func countBadge(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func loadError(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
            Text(message).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.red)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Read-only view of routes.json so you can see what Jev is choosing between
/// without opening the file. Editing stays in the JSON on purpose: the
/// descriptions are prompts, and a text editor is the right tool for prose.
private struct RouteTree: View {
    let roots: [RouteNode]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(roots.enumerated()), id: \.offset) { _, node in
                row(node, depth: 0)
                ForEach(Array((node.children ?? []).enumerated()), id: \.offset) { _, child in
                    row(child, depth: 1)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.09), lineWidth: 1))
    }

    private func row(_ node: RouteNode, depth: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.isScanning ? "folder.badge.gearshape" : (node.children == nil ? "folder" : "folder.fill"))
                .font(.system(size: 10))
                .foregroundStyle(node.isScanning ? Color.orange : .secondary)
                .frame(width: 14)
            Text(node.label)
                .font(.system(size: 11, weight: depth == 0 ? .medium : .regular))
            Text(shortPath(node.path ?? node.scan))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if node.isScanning {
                Chip(text: node.allowNew == true ? "picks a subfolder, may propose new" : "picks a subfolder", tint: .orange)
            }
        }
        .padding(.leading, 10 + CGFloat(depth) * 18)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .help(node.description)
    }

    private func shortPath(_ p: String?) -> String {
        guard let p else { return "" }
        return p.replacingOccurrences(of: DestinationRoot.placeholder + "/", with: "")
                .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// One bar showing all three bands at once. Reading "where does 72% land" off a
/// pair of separate sliders is work; here it is just a colour.
private struct ThresholdBand: View {

    @Binding var ask: Double
    @Binding var auto: Double

    @State private var draftAsk: Double?
    @State private var draftAuto: Double?

    private var liveAsk: Double { draftAsk ?? ask }
    private var liveAuto: Double { draftAuto ?? auto }

    private let barHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geometry in
                let width = geometry.size.width

                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        zone(.secondary, width: width * liveAsk)
                        zone(.blue, width: width * (liveAuto - liveAsk))
                        zone(.green, width: width * (1 - liveAuto))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    handle(at: width * liveAsk)
                        .gesture(drag(width: width, isAsk: true))
                    handle(at: width * liveAuto)
                        .gesture(drag(width: width, isAsk: false))
                }
            }
            .frame(height: barHeight)

            HStack(spacing: 14) {
                legend(color: .secondary, label: "Leave alone", value: "under \(percent(liveAsk))")
                legend(color: .blue, label: "Ask me", value: "\(percent(liveAsk))–\(percent(liveAuto))")
                legend(color: .green, label: "File it", value: "over \(percent(liveAuto))")
                Spacer()
                // Typed entry for anyone who cannot or would rather not drag.
                stepper("ask", value: $ask, range: 0.02...max(0.02, auto - 0.03))
                stepper("file", value: $auto, range: min(0.99, ask + 0.03)...0.99)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confidence thresholds: ask above \(percent(ask)), file on its own above \(percent(auto))")
    }

    private func stepper(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            Stepper(value: Binding(
                get: { (value.wrappedValue * 100).rounded() },
                set: { value.wrappedValue = min(max($0 / 100, range.lowerBound), range.upperBound) }
            ), in: (range.lowerBound * 100)...(range.upperBound * 100), step: 1) {
                Text(percent(value.wrappedValue))
                    .font(.system(size: 9.5, design: .monospaced))
                    .frame(width: 30, alignment: .trailing)
            }
            .controlSize(.mini)
            .accessibilityLabel("\(label) threshold")
        }
    }

    private func zone(_ color: Color, width: CGFloat) -> some View {
        Rectangle()
            .fill(color.opacity(0.28))
            .frame(width: max(0, width), height: barHeight)
    }

    private func handle(at x: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(Color.primary.opacity(0.35), lineWidth: 1))
            .frame(width: 5, height: barHeight + 7)
            .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.5)
            // A 5pt handle is a 5pt target. The grab area is wider than the
            // drawn handle, which is what every native slider does too.
            .frame(width: 22, height: barHeight + 7)
            .contentShape(Rectangle())
            .position(x: x, y: barHeight / 2)
    }

    private func drag(width: CGFloat, isAsk: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let fraction = min(max(value.location.x / width, 0.02), 0.99)
                if isAsk {
                    draftAsk = min(fraction, liveAuto - 0.03)
                } else {
                    draftAuto = max(fraction, liveAsk + 0.03)
                }
            }
            // Commit on release only: writing through on every frame would rewrite
            // settings.json for the whole length of the drag.
            .onEnded { _ in
                if let draftAsk { ask = draftAsk }
                if let draftAuto { auto = draftAuto }
                draftAsk = nil
                draftAuto = nil
            }
    }

    private func legend(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.45))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 10, weight: .medium))
                Text(value)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

// MARK: - Privacy

struct PrivacyTab: View {

    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var draftKey = ""
    @State private var saved = false
    @State private var keychain: KeyStore.KeychainState = .absent
    @State private var keySource: KeyStore.Source = .missing

    private func refresh() {
        keychain = KeyStore.keychainState()
        keySource = KeyStore.source()
    }

    /// Says which of the three situations you are in, because "no key" and
    /// "a key is there but this build cannot read it" need different fixes.
    private var statusLine: String {
        switch keychain {
        case .presentButUnreadable:
            return "A key is in the keychain but this build cannot read it — the keychain grants access per binary, and rebuilding changes the binary. Paste it again to re-save, or set JEV_API_KEY in the environment."
        case .readable:
            return saved ? "Saved to the keychain." : "Stored in the keychain. The environment takes precedence if JEV_API_KEY is set there."
        case .absent:
            return "Nothing stored in the keychain. Usher is reading the environment, or has no key at all. Setting one here stores it for this account only."
        }
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: Layout.section) {
                Section(title: "API key") {
                    HStack(spacing: 8) {
                        Image(systemName: keySource == .missing ? "xmark.seal.fill" : "checkmark.seal.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(keySource == .missing ? Color.red : .green)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(keySource == .missing ? "No key found" : "Loaded")
                                .font(.system(size: 12, weight: .medium))
                            Text(keySource.displayName)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((keySource == .missing ? Color.red : Color.green).opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                    HStack(spacing: 8) {
                        SecureField("Paste a TypeSafe API key to store in the keychain", text: $draftKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))

                        Button("Save") {
                            saved = KeyStore.saveToKeychain(draftKey)
                            // Files that waited for a key go now, not at the next pass.
                            if saved { AppState.shared.pipeline.retryNow() }
                            draftKey = ""
                            refresh()
                        }
                        .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Remove") {
                            KeyStore.removeFromKeychain()
                            saved = false
                            refresh()
                        }
                        .disabled(keychain == .absent)
                    }

                    Text(statusLine)
                        .font(.system(size: 10))
                        .foregroundStyle(keychain == .presentButUnreadable ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                Section(title: "Never send to the API",
                        subtitle: "A match holds the file on this machine; a local rule may still file it. One entry per line, whole words.") {
                    HStack(alignment: .top, spacing: 12) {
                        PatternEditor(
                            caption: "Filename or title contains",
                            symbol: "textformat",
                            height: 118,
                            lines: Binding(
                                get: { settingsStore.settings.sensitivePatterns },
                                set: { settingsStore.settings.sensitivePatterns = $0 }
                            )
                        )
                        PatternEditor(
                            caption: "Downloaded from host containing",
                            symbol: "globe",
                            height: 118,
                            lines: Binding(
                                get: { settingsStore.settings.sensitiveHosts },
                                set: { settingsStore.settings.sensitiveHosts = $0 }
                            )
                        )
                    }

                    // Was only editable in settings.json. It is the one list
                    // that is entirely about you, so it belongs on this tab.
                    PatternEditor(
                        caption: "Your own identifiers — emails, phone numbers, street address. A file containing one is never sent.",
                        symbol: "person.text.rectangle",
                        height: 62,
                        lines: Binding(
                            get: { settingsStore.settings.personalIdentifiers },
                            set: { settingsStore.settings.personalIdentifiers = $0 }
                        )
                    )

                    Text("Also held locally: \(settingsStore.settings.sensitiveExtensions.count) file types, \(settingsStore.settings.sensitiveContentPatterns.count) content phrases, \(settingsStore.settings.sensitiveImageLabels.count) image labels, plus password-manager and key formats that can never be sent at all. Edit those in settings.json.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(.purple)
                    Text("Order of checks, all on this machine: secrets by name or format · secrets by content · local rules · the lists above. Only what passes every one reaches the model, as a short excerpt — never the file — and the request itself is screened once more right before it is sent. As a last backstop the model is asked whether the excerpt reads like a personal record, and a yes holds the file where it is.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(9)
                .background(Color.purple.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))

        }
        .padding(Layout.padding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { refresh() }
    }
}

private struct PatternEditor: View {
    let caption: String
    let symbol: String
    var height: CGFloat = 120
    @Binding var lines: [String]

    /// Local text, committed to settings after a pause. A binding that split,
    /// trimmed and re-joined on every keystroke swallowed the newline the
    /// moment Return was pressed — you could not add a line — and rewrote
    /// settings.json per character.
    @State private var text = ""
    @State private var commit: Task<Void, Never>?

    private func push() {
        let parsed = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parsed != lines { lines = parsed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9)).padding(.top, 1)
                Text(caption).font(.system(size: 10, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)

            TextEditor(text: $text)
            .accessibilityLabel(caption)
            .onAppear { text = lines.joined(separator: "\n") }
            .onChange(of: text) {
                commit?.cancel()
                commit = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    push()
                }
            }
            .onDisappear { commit?.cancel(); push() }
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: height)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )

            Text("\(lines.count) pattern\(lines.count == 1 ? "" : "s")")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Guide

/// The same legend the panel shows, with room to breathe. Written once in
/// `Legend`, so the two can never say different things.
struct GuideTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.section) {
                Section(title: "How a file gets filed",
                        subtitle: "Every file goes through the same order, and most of it never leaves this machine.") {
                    VStack(alignment: .leading, spacing: 6) {
                        step(1, "Wait until it has finished downloading.")
                        step(2, "Read it here — text, OCR, archive listing, media metadata. Nothing is sent yet.")
                        step(3, "Secrets stop — by name or format before the file is opened (vaults, keys, recovery codes, password exports), then by content once it is read here. Never sent, never moved.")
                        step(4, "Local rules file it by code, with nothing sent.")
                        step(5, "Privacy lists hold it here if anything matches.")
                        step(6, "What is left goes to the model as a short excerpt — never the file — which picks a folder and a name. The request is screened once more right before it leaves.")
                        step(7, "Above your file threshold it moves; between the thresholds it asks; below, it stays where it is.")
                    }
                }

                Divider()

                Section(title: "What a row says") { table(Legend.outcomes) }

                Divider()

                Section(title: "What the buttons do",
                        subtitle: "Show and Move to Trash appear when the pointer is over a row; the rest depend on what the row is.") {
                    table(Legend.actions)
                }

                Divider()

                Section(title: "Along the bottom of the panel") { table(Legend.footer) }

                Divider()

                Section(title: "The confidence bar") {
                    Text(Legend.confidence)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Layout.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("\(n)")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .frame(width: 15, height: 15)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func table(_ items: [Legend.Item]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(item.tint)
                        .frame(width: 16, height: 15)
                    Text(item.name)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 104, alignment: .leading)
                    Text(item.meaning)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                if index < items.count - 1 { Divider().opacity(0.35).padding(.leading, 34) }
            }
        }
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.09), lineWidth: 1))
    }
}
