import Foundation

/// Headless mode. Runs the same extract → filter → classify → plan path the app
/// uses, prints what it would do, and never moves anything. This is the loop for
/// evaluating routes.json against real files.
enum CLI {

    static func run(arguments: [String]) async -> Int32 {
        var paths: [String] = []
        var verbose = false

        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--dir":
                i += 1
                guard i < arguments.count else {
                    FileHandle.standardError.write(Data("--dir needs a folder\n".utf8))
                    return 2
                }
                let dir = URL(fileURLWithPath: (arguments[i] as NSString).expandingTildeInPath)
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                paths += contents.filter { !$0.hasDirectoryPath }.map(\.path)
            case "--verbose", "-v":
                verbose = true
            case "--help", "-h":
                printUsage()
                return 0
            default:
                paths.append(arguments[i])
            }
            i += 1
        }

        guard !paths.isEmpty else {
            printUsage()
            return 2
        }

        let settings = loadSettings()
        let routes = RouteTable.load()
        guard !routes.leaves.isEmpty else {
            FileHandle.standardError.write(Data("routes.json has no destinations\n".utf8))
            return 1
        }

        let rules = LocalRules.load()
        func classifier(for url: URL) -> Classifier {
            Classifier(model: settings.model, routes: routes, root: DestinationRoot.root(for: url, settings: settings), settings: settings)
        }
        var totalIn = 0, totalOut = 0

        // Start every iCloud download at once rather than one per file in turn.
        if settings.downloadCloudFiles {
            let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let placeholders = urls.filter { CloudFile.availability(of: $0) == .placeholder }
            if !placeholders.isEmpty {
                print("iCloud: requesting \(placeholders.count) placeholder\(placeholders.count == 1 ? "" : "s")…\n")
                CloudFile.prefetch(placeholders)
            }
        }

        for path in paths.sorted() {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("  ?  \(url.lastPathComponent) — not found")
                continue
            }
            if StabilityGate.shouldIgnore(url) || StabilityGate.isPartial(url) { continue }

            if SecretFormats.isSecret(url, settings: settings) {
                print(" 🔑 \(url.lastPathComponent)")
                print("      password manager or key material — never classified")
                continue
            }

            let started = Date()

            if CloudFile.availability(of: url) != .local {
                let sizeMB = Int(CloudFile.size(of: url) / 1_048_576)
                guard settings.downloadCloudFiles, sizeMB <= settings.maxCloudDownloadMB else {
                    print(" ☁️  \(url.lastPathComponent)")
                    print("      iCloud placeholder (\(sizeMB)MB) — not downloaded, skipped")
                    continue
                }
                print(" ☁️  \(url.lastPathComponent) — downloading from iCloud…")
                guard await CloudFile.materialize(url) else {
                    print("      download timed out, skipped")
                    continue
                }
            }

            let evidence = EvidenceExtractor.extract(from: url)

            // Deterministic rules first — these never reach the API at all.
            if let hit = LocalRules.match(evidence, rules: rules) {
                let plan = Mover.plan(source: url,
                                      folder: hit.rule.destinationURL(root: DestinationRoot.root(for: url, settings: settings)),
                                      template: hit.rule.template ?? "{name}.{ext}",
                                      chosenName: evidence.filename,
                                      evidence: evidence)
                print(" 📌 \(url.lastPathComponent)")
                print("      rule \"\(hit.rule.name)\" matched on \(hit.matchedOn) — nothing sent")
                print("      → \(plan.destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                continue
            }

            let verdict = SensitiveFilter.check(evidence, settings: settings)
            if verdict.isSensitive {
                print(" 🔒 \(url.lastPathComponent)")
                print("      held locally — \(verdict.reason ?? "matched a privacy pattern"); nothing sent")
                continue
            }

            do {
                let decision = try await classifier(for: url).classify(evidence)
                let elapsed = Date().timeIntervalSince(started)
                totalIn += decision.usage?.input_tokens ?? 0
                totalOut += decision.usage?.output_tokens ?? 0
                report(url: url, evidence: evidence, decision: decision,
                       routes: routes, settings: settings, elapsed: elapsed, verbose: verbose)
            } catch {
                print(" ⚠️  \(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }

        if totalIn > 0 {
            print("")
            print("tokens: \(totalIn) in / \(totalOut) out")
        }
        return 0
    }

    private static func report(url: URL,
                               evidence: Evidence,
                               decision: Classifier.Decision,
                               routes: RouteTable,
                               settings: AppSettings,
                               elapsed: TimeInterval,
                               verbose: Bool) {

        let probability = decision.pathScore
        let marker: String
        if decision.sensitiveByModel >= 0.5 {
            marker = "🔒"
        } else if decision.needsNewFolder {
            marker = "🆕"
        } else if decision.isUnsorted || decision.destination == nil {
            marker = "📥"
        } else if probability >= settings.autoMoveThreshold {
            marker = "✅"
        } else if probability >= settings.askThreshold {
            marker = "❓"
        } else {
            marker = "➖"
        }

        print(" \(marker) \(url.lastPathComponent)")

        if decision.sensitiveByModel >= 0.5 {
            print(String(format: "      held — reads as a personal record (%.0f%%)",
                         decision.sensitiveByModel * 100))
            return
        }

        func shorten(_ path: String) -> String {
            path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }

        if decision.needsNewFolder,
           let parent = decision.newFolderParent,
           let proposed = decision.proposedFolderName {
            let plan = Mover.plan(source: url,
                                  folder: parent.appendingPathComponent(proposed),
                                  template: decision.template,
                                  chosenName: decision.chosenName,
                                  evidence: evidence)
            print("      no existing folder fits — would ASK to create \"\(proposed)\"")
            print(String(format: "      → %@  (%.0f%%, %.1fs)",
                         shorten(plan.destination.path), probability * 100, elapsed))
        } else if let destination = decision.destination {
            let plan = Mover.plan(source: url,
                                  folder: destination,
                                  template: decision.template,
                                  chosenName: decision.chosenName,
                                  evidence: evidence)
            print(String(format: "      → %@  (%.0f%%, conf %.2f, %.1fs)",
                         shorten(plan.destination.path), probability * 100,
                         decision.routeConfidence, elapsed))
            if let folder = decision.folderName {
                print("      matched existing folder \"\(folder)\"")
            }
        } else {
            print(String(format: "      → stays put, no folder matched  (%.0f%%, %.1fs)",
                         probability * 100, elapsed))
        }

        if verbose {
            let runners = decision.probabilities
                .sorted { $0.value > $1.value }
                .prefix(4)
                .map { String(format: "%@ %.2f", $0.key, $0.value) }
                .joined(separator: "   ")
            print("      \(runners)")
            if evidence.nameCandidates.count > 1 {
                print("      names offered: \(evidence.nameCandidates.joined(separator: " | "))")
            }
            if let host = evidence.sourceHost {
                print("      from: \(host)")
            }
        }
    }

    /// Headless watcher, for checking the FSEvents path without launching the GUI.
    /// Same stream and same settle gate the app uses; nothing is ever moved.
    static func watch() async -> Int32 {
        let settings = loadSettings()
        let routes = RouteTable.load()
        let folders = settings.watchFolders.filter { $0.enabled && $0.exists }

        guard !folders.isEmpty else {
            FileHandle.standardError.write(Data("no watchable folders in settings.json\n".utf8))
            return 1
        }

        for folder in folders {
            let mode = folder.recursive ? " (+ subfolders)" : ""
            print("watching \(folder.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))\(mode)")
        }
        print("dry run — nothing will move. ctrl-c to stop.\n")

        func classifier(for url: URL) -> Classifier {
            Classifier(model: settings.model, routes: routes, root: DestinationRoot.root(for: url, settings: settings), settings: settings)
        }
        let seen = Seen()

        let watcher = FolderWatcher { urls in
            for url in urls {
                guard !StabilityGate.shouldIgnore(url), !StabilityGate.isPartial(url) else { continue }
                Task {
                    guard await seen.claim(url.path) else { return }
                    defer { Task { await seen.release(url.path) } }

                    guard let settled = await StabilityGate.waitUntilStable(url) else { return }
                    // The same order as the app: a link is not followed, a
                    // secret is not opened, a rule keeps it local. `watch` used
                    // to go straight from extraction to the privacy filter.
                    if (try? settled.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return }
                    if SecretFormats.isSecret(settled, settings: settings) {
                        print(" 🔑 \(settled.lastPathComponent)")
                        print("      a secret by its name or format — never classified")
                        return
                    }
                    let evidence = EvidenceExtractor.extract(from: settled)
                    if let kind = SecretContent.detect(evidence) {
                        print(" 🔑 \(settled.lastPathComponent)")
                        print("      contains what looks like \(kind) — never sent")
                        return
                    }
                    if let hit = LocalRules.match(evidence, rules: LocalRules.load()) {
                        print(" 📌 \(settled.lastPathComponent)")
                        print("      rule \"\(hit.rule.name)\" matched on \(hit.matchedOn) — nothing sent")
                        return
                    }

                    let verdict = SensitiveFilter.check(evidence, settings: settings)
                    if verdict.isSensitive {
                        print(" 🔒 \(settled.lastPathComponent)")
                        print("      held locally — \(verdict.reason ?? "matched a pattern"); nothing sent")
                        return
                    }

                    let started = Date()
                    do {
                        let decision = try await classifier(for: url).classify(evidence)
                        report(url: settled, evidence: evidence, decision: decision,
                               routes: routes, settings: settings,
                               elapsed: Date().timeIntervalSince(started), verbose: false)
                    } catch {
                        print(" ⚠️  \(settled.lastPathComponent) — \(error.localizedDescription)")
                    }
                }
            }
        }

        watcher.start(folders: folders)
        // FSEvents delivers on its own dispatch queue; park the main thread.
        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Guards against FSEvents reporting the same file more than once.
    private actor Seen {
        private var paths = Set<String>()

        func claim(_ path: String) -> Bool {
            guard !paths.contains(path) else { return false }
            paths.insert(path)
            return true
        }

        func release(_ path: String) {
            paths.remove(path)
        }
    }

    private static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: Paths.settings),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    private static func printUsage() {
        print("""
        Usage:
          Usher classify <file>...        classify specific files
          Usher classify --dir <folder>   classify everything in a folder
          Usher classify --dir ~/Downloads --verbose

        Nothing is moved. Prints the folder and name each file would get.

          ✅ would move    ❓ would ask    ➖ too uncertain
          📥 no match      🆕 wants a new folder (always asks)   🔒 held, never sent
        """)
    }
}
