import Foundation
import Combine

/// Watch → settle → extract → filter → classify → act. Code owns every step;
/// Jev only supplies the two selections in the middle.
@MainActor
final class Pipeline: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published var routes: RouteTable = .load()
    @Published var rules: [LocalRule] = LocalRules.load()
    @Published var rulesLoadError: String? = LocalRules.loadResult().error

    private let settingsStore: SettingsStore
    private let journal: Journal
    private var watcher: FolderWatcher?
    private var inFlight = Set<String>()
    /// Paths an undo just put back. The move-back fires an FSEvent, and without
    /// this the watcher re-classified and re-moved the file seconds after the
    /// user reversed it — undo did not stick.
    private var recentlyUndone = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    init(settingsStore: SettingsStore, journal: Journal) {
        self.settingsStore = settingsStore
        self.journal = journal

        // Restart the stream whenever the watch list changes in settings.
        settingsStore.$watchGeneration
            .dropFirst()
            .sink { [weak self] _ in self?.restart() }
            .store(in: &cancellables)

        // Dry run and the thresholds are policy: when they change, the answers
        // already in the journal are re-applied here, and nothing is re-sent.
        // Debounced because the threshold steppers commit once per click.
        settingsStore.$settings
            .map { Policy($0) }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reapplyPolicy() }
            .store(in: &cancellables)
    }

    /// What your thresholds say to do with an answer. Creating a folder is never
    /// automatic, whatever the probability.
    nonisolated static func policyOutcome(probability p: Double, createsFolder: Bool,
                                          auto: Double, ask: Double) -> Outcome {
        if createsFolder { return p >= ask ? .pendingApproval : .lowConfidence }
        if p >= auto { return .moved }
        if p >= ask { return .pendingApproval }
        return .lowConfidence
    }

    private struct Policy: Equatable {
        let dryRun: Bool, auto: Double, ask: Double
        init(_ s: AppSettings) { dryRun = s.dryRun; auto = s.autoMoveThreshold; ask = s.askThreshold }
    }

    /// Re-decides every stored answer whose outcome depends on policy, using the
    /// probability and destination already in the journal. Not one API call:
    /// the answer did not change, only what you want done with it.
    ///
    /// Leaves alone: folder units (always your call), folder creation (always
    /// your call), anything you told to stay, and files that have moved since.
    func reapplyPolicy() {
        let settings = settingsStore.settings
        // Turning dry run on stops new moves. It must not reword decisions
        // already made — a waiting proposal stays a waiting proposal.
        guard !settings.dryRun, !journal.isLocked else { policyMovesWaiting = []; return }
        let folders = settings.watchFolders.filter(\.enabled).map(\.url)

        var moves: [JournalEntry] = []
        for var entry in journal.redecidable(in: folders) {
            guard let p = entry.routeProbability else { continue }
            let target = Self.policyOutcome(probability: p, createsFolder: entry.createsFolder,
                                            auto: settings.autoMoveThreshold, ask: settings.askThreshold)
            guard target != entry.outcome else { continue }
            if target == .moved { moves.append(entry); continue }
            entry.timestamp = Date()
            entry.cleared = false
            entry.outcome = target
            entry.reason = switch target {
            case .pendingApproval: entry.createsFolder
                ? "Would create \"\(entry.proposedFolderName ?? "a folder")\" — always your call."
                : "Between your thresholds."
            default: "Below your ask threshold."
            }
            journal.update(entry)
        }
        // Moving files is not something a toggle should do by surprise: one
        // click on the Dry run pill used to file every preview above the
        // threshold 1.5 seconds later. The panel asks first.
        policyMovesWaiting = moves
    }

    /// Previews that the new policy would file, waiting for a yes.
    @Published private(set) var policyMovesWaiting: [JournalEntry] = []

    func confirmPolicyMoves() {
        let batch = policyMovesWaiting
        policyMovesWaiting = []
        Task { await self.moveFromStoredAnswers(batch, why: "the dry run was turned off or a threshold changed") }
    }

    func declinePolicyMoves() { policyMovesWaiting = [] }

    /// Files moved together by one action, so they can be put back together.
    @Published private(set) var lastBulkMove: [UUID] = []

    func undoLastBulkMove() {
        let ids = Set(lastBulkMove)
        lastBulkMove = []
        for entry in journal.entries where ids.contains(entry.id) && entry.canUndo { undo(entry) }
    }

    private func moveFromStoredAnswers(_ batch: [JournalEntry], why: String) async {
        var moved: [UUID] = []
        for var entry in batch {
            guard let proposed = entry.proposedPath else { continue }
            let source = URL(fileURLWithPath: entry.originalPath)
            entry.timestamp = Date()
            entry.cleared = false
            if let refusal = await refusal(for: source) {
                entry.outcome = .neverClassified
                entry.reason = "Not moved: \(refusal)."
                journal.update(entry); continue
            }
            let destination = URL(fileURLWithPath: proposed)
            // Time has passed since the answer; the destination may have
            // gained this very file.
            if case .duplicateOf(let existing) = Duplicates.check(source, against: destination.deletingLastPathComponent()) {
                entry.outcome = .duplicate
                entry.duplicateOf = existing.path
                entry.reason = "Identical to \"\(existing.lastPathComponent)\" already filed there."
            } else {
                do {
                    let final = try Mover.apply(Mover.Plan(source: source, destination: destination))
                    entry.outcome = .moved
                    entry.finalPath = final.path
                    entry.reason = "Filed when \(why) — from the answer already in the log, nothing sent."
                    moved.append(entry.id)
                } catch {
                    entry.outcome = .failed
                    entry.reason = error.localizedDescription
                }
            }
            journal.update(entry)
        }
        if moved.count > 1 { lastBulkMove = moved }
    }

    /// The floor once more, at the moment a file is about to move. A decision
    /// can wait for days under the rules of the day it was made; this is the
    /// one gate every move — approve, Move all, a policy change — goes through.
    /// Returns why not, or nil to go ahead.
    private func refusal(for url: URL) async -> String? {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return "it is a symbolic link, which Usher does not follow"
        }
        let settings = settingsStore.settings
        if SecretFormats.isSecret(url, settings: settings) { return "it is a secret by its name or format" }
        if url.hasDirectoryPath {
            // A folder moves whole. One secret inside is reason enough to let
            // you move it yourself.
            let hit = await Task.detached(priority: .userInitiated) { () -> String? in
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
                var seen = 0
                while let item = e?.nextObject() as? URL, seen < 20_000 {
                    seen += 1
                    if SecretFormats.isSecret(item, settings: settings) { return item.lastPathComponent }
                }
                return nil
            }.value
            return hit.map { _ in "the folder contains a secret file — move it yourself" }
        }
        let evidence = await Task.detached(priority: .userInitiated) { EvidenceExtractor.extract(from: url) }.value
        return SecretContent.detect(evidence).map { "it contains what looks like \($0)" }
    }

    func start() {
        refreshKeyState()
        guard !journal.isLocked else {
            lastError = Self.lockedMessage
            return
        }
        let watcher = FolderWatcher { [weak self] urls in
            Task { @MainActor in self?.enqueue(urls) }
        }
        watcher.start(folders: settingsStore.settings.watchFolders)
        self.watcher = watcher
        isRunning = true
        scheduleCatchUp()
    }

    func stop() {
        catchUpTask?.cancel()
        catchUpTask = nil
        watcher?.stop()
        watcher = nil
        isRunning = false
    }

    // MARK: - Catch-up

    /// The watcher only ever sees arrivals. Everything already in a live folder
    /// when the app starts — 212 of 245 files in one Downloads — would otherwise
    /// sit there forever. One pass now, then one per interval.
    private func scheduleCatchUp() {
        catchUpTask?.cancel()
        catchUpTask = Task { [weak self] in
            guard let self else { return }
            await self.catchUp()
            while !Task.isCancelled {
                let minutes = max(5, self.settingsStore.settings.autoSweepMinutes)
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
                if Task.isCancelled { break }
                await self.catchUp()
            }
        }
    }

    func catchUp() async {
        guard settingsStore.settings.autoSweep, !journal.isLocked else { return }
        apiUnavailable = false
        var pending: [URL] = []
        for folder in settingsStore.settings.watchFolders where folder.enabled && folder.exists {
            pending += Self.files(in: folder)
            pending += Self.units(in: folder, settings: settingsStore.settings, rules: rules)
        }
        pending = pending.filter {
            journal.needsDecision($0.path, identity: FileIdentity.of($0))
                && !inFlight.contains($0.canonicalPath)
        }
        guard !pending.isEmpty else { return }

        // Three at a time: the network waits overlap, the extraction does not
        // pile up, and the API is not hit with two hundred requests at once.
        // Actor state is touched here, on the actor; the group's closure is not
        // isolated and only awaits into `process`, which is.
        for url in pending { inFlight.insert(url.canonicalPath) }
        catchUpProgress = (0, pending.count)
        var iterator = pending.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                if let url = iterator.next() {
                    group.addTask { await self.process(url, key: url.canonicalPath) }
                }
            }
            for await _ in group {
                await self.noteCatchUpStep()
                // The API is down or the key is missing: stop, rather than run
                // every remaining file into the same wall. The rest are released
                // untouched and the next pass tries again.
                if await self.apiUnavailable { continue }
                if let url = iterator.next() {
                    group.addTask { await self.process(url, key: url.canonicalPath) }
                }
            }
        }
        while let url = iterator.next() { inFlight.remove(url.canonicalPath) }
        catchUpProgress = nil
    }

    private func noteCatchUpStep() {
        catchUpProgress?.done += 1
    }

    /// Subfolders of a watched folder that are one thing each. Only for
    /// non-recursive watches: a recursive watch already sees the files inside.
    static func units(in folder: WatchFolder, settings: AppSettings, rules: [LocalRule]) -> [URL] {
        guard !folder.recursive else { return [] }
        let dirs = ((try? FileManager.default.contentsOfDirectory(
            at: folder.url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter(\.hasDirectoryPath)
        // A folder that is itself a route destination, a scan root, a rule
        // destination, or an ancestor of one is never a unit: proposing to move
        // ~/Downloads/Software into ~/Downloads/Software/Source is nonsense.
        let protected = Self.protectedPaths(settings: settings, rules: rules, table: .load())
        return dirs.filter { dir in
            guard !FolderUnit.isExcluded(dir, settings: settings) else { return false }
            let d = dir.canonicalPath
            if protected.contains(where: { $0 == d || $0.hasPrefix(d + "/") }) { return false }
            // A rule that names the folder makes it a unit outright — that is how
            // "A1" under Downloads/German becomes iCloud/German/A1 whole, instead
            // of 113 audio tracks poured into a flat folder.
            if rules.contains(where: { r in
                r.filenamePattern.map { dir.lastPathComponent.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil } ?? false
            }) { return true }
            return FolderUnit.isUnit(dir, shape: FolderUnit.shape(of: dir))
        }
    }

    nonisolated static func protectedPaths(settings: AppSettings, rules: [LocalRule],
                                           table: RouteTable) -> [String] {
        var paths: [String] = []
        for root in DestinationRoot.allRoots(settings: settings) {
            paths += table.leaves.map { $0.destination(root: root).canonicalPath }
            paths += table.scans.map { $0.root(for: root).canonicalPath }
            paths += rules.map { $0.destinationURL(root: root).canonicalPath }
        }
        paths.append(URL(fileURLWithPath: (settings.duplicatesFolder as NSString).expandingTildeInPath).canonicalPath)
        return paths
    }

    static func files(in folder: WatchFolder) -> [URL] {
        let manager = FileManager.default
        var urls: [URL] = []
        if folder.recursive {
            guard let e = manager.enumerator(at: folder.url, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
            urls = e.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }
        } else {
            urls = ((try? manager.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])) ?? [])
                .filter { !$0.hasDirectoryPath }
        }
        return urls.filter { !StabilityGate.shouldIgnore($0) && !StabilityGate.isPartial($0) }
    }

    func restart() {
        stop()
        routes = .load()
        let loaded = LocalRules.loadResult()
        rules = loaded.rules
        rulesLoadError = loaded.error
        ConfigFingerprint.invalidate()
        start()
    }

    func reloadRoutes() {
        routes = .load()
        let loaded = LocalRules.loadResult()
        rules = loaded.rules
        rulesLoadError = loaded.error
        ConfigFingerprint.invalidate()
    }

    // MARK: - Queue

    private func enqueue(_ urls: [URL], userInitiated: Bool = false) {
        // Locked means nothing is recorded, so nothing may happen: a drop on the
        // icon used to be classified, sent and moved with no journal line and
        // no undo.
        guard !journal.isLocked else { lastError = Self.lockedMessage; return }
        for url in urls {
            guard !StabilityGate.shouldIgnore(url), !StabilityGate.isPartial(url) else { continue }
            let key = url.canonicalPath
            if recentlyUndone.remove(key) != nil { continue }
            guard !inFlight.contains(key) else { continue }
            inFlight.insert(key)
            queue.append((url, key, userInitiated))
        }
        pump()
    }

    /// Arrivals and drops, three at a time. Unzipping five hundred files into
    /// Downloads used to start five hundred extractions and five hundred
    /// requests at once.
    private var queue: [(url: URL, key: String, userInitiated: Bool)] = []
    private var running = 0

    private func pump() {
        while running < 3, !queue.isEmpty {
            let job = queue.removeFirst()
            running += 1
            Task {
                await process(job.url, key: job.key, userInitiated: job.userInitiated)
                running -= 1
                pump()
            }
        }
    }

    static let lockedMessage = "Usher can't open its journal: macOS didn't allow access to its key. Nothing is filed until it can — relaunch Usher and choose Always Allow."

    /// Set when the API is unreachable, rejects the key, or there is no key.
    /// Cleared at the start of each pass and on the next successful answer.
    @Published private(set) var apiUnavailable = false

    /// Whether any API key is configured — checked without reading its value,
    /// so it never raises a keychain prompt.
    @Published private(set) var hasAPIKey = true

    func refreshKeyState() {
        let env = ProcessInfo.processInfo.environment
        hasAPIKey = !(env["JEV_API_KEY"] ?? "").isEmpty || !(env["TYPESAFE_API_KEY"] ?? "").isEmpty
            || KeyStore.keychainState() != .absent
    }

    /// "Try again" from the panel: after saving a key, or after an outage.
    func retryNow() {
        refreshKeyState()
        apiUnavailable = false
        if lastError != Self.lockedMessage { lastError = nil }
        Task { await catchUp() }
    }

    /// Files dropped on the panel. Handing the app a file is an explicit request to
    /// file it, so these clear a lower bar than something that merely appeared.
    func acceptDrop(_ urls: [URL]) {
        droppedRecently = urls.count
        // Dropping a vault on the icon is still a no: it gets one journal line
        // saying so, via the gate in process(), and nothing else.
        enqueue(urls.filter { !$0.hasDirectoryPath }, userInitiated: true)
    }

    @Published var droppedRecently: Int = 0
    /// Non-nil while a catch-up pass is running: (done, total).
    @Published private(set) var catchUpProgress: (done: Int, total: Int)?
    /// Files being worked on right now, from any source.
    @Published private(set) var activeCount = 0
    var isBusy: Bool { activeCount > 0 || catchUpProgress != nil }
    private var catchUpTask: Task<Void, Never>?

    private func process(_ url: URL, key: String, userInitiated: Bool = false) async {
        activeCount += 1
        defer { inFlight.remove(key); activeCount -= 1 }
        guard !journal.isLocked else { return }
        // A link is not the file. Archive Utility keeps symlinks when it
        // unzips; a "notes.txt" pointing elsewhere would pass the floor on its
        // own name and then have its target read and sent.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return }

        let settings = settingsStore.settings

        // A folder is filed as one unit: described from its listing, routed by
        // the same rules and filter, and then always left waiting for approval —
        // moving 47,000 files on a probability is not something this app does.
        if url.hasDirectoryPath {
            await processUnit(url, settings: settings)
            return
        }

        guard let settled = await StabilityGate.waitUntilStable(url) else { return }
        guard FileManager.default.fileExists(atPath: settled.path) else { return }

        // Password vaults, keys, wallets: the pipeline stops here. Nothing below
        // this line runs for them — no download, no extraction, no rule, no move.
        if SecretFormats.isSecret(settled, settings: settings) {
            journal.record(JournalEntry(
                originalPath: settled.path,
                filename: settled.lastPathComponent,
                outcome: .neverClassified,
                reason: "A secret by its name or format — a vault, key, recovery codes or credentials. Never read, never sent, never moved."
            ))
            return
        }

        // An iCloud placeholder reads as an empty file. Materialize it, or record
        // that we could not — never classify on bytes that were never there.
        if CloudFile.availability(of: settled) != .local {
            let sizeMB = Int(CloudFile.size(of: settled) / 1_048_576)
            guard settings.downloadCloudFiles, sizeMB <= settings.maxCloudDownloadMB else {
                journal.record(JournalEntry(
                    originalPath: settled.path,
                    filename: settled.lastPathComponent,
                    outcome: .lowConfidence,
                    reason: settings.downloadCloudFiles
                        ? "iCloud placeholder, \(sizeMB)MB — over the download limit"
                        : "iCloud placeholder — downloading is off"
                ))
                return
            }
            guard await CloudFile.materialize(settled) else {
                journal.record(JournalEntry(
                    originalPath: settled.path,
                    filename: settled.lastPathComponent,
                    outcome: .lowConfidence,
                    reason: "iCloud placeholder — could not download in time"
                ))
                return
            }
        }

        let evidence = await Task.detached(priority: .utility) {
            EvidenceExtractor.extract(from: settled)
        }.value

        // A secret whose name gave nothing away. Before rules and before Jev:
        // not sent, not filed, not renamed — and the journal records what kind
        // of secret it looked like, never the text that matched.
        if let kind = SecretContent.detect(evidence) {
            journal.record(JournalEntry(
                originalPath: settled.path,
                filename: settled.lastPathComponent,
                outcome: .neverClassified,
                reason: "Contains what looks like \(kind) — never sent, never moved."
            ))
            return
        }

        // Deterministic rules come first. A file matched here is filed by code and
        // never reaches the API — which is the only way a document that must stay
        // private can still end up in the right folder.
        if let hit = LocalRules.match(evidence, rules: rules) {
            fileByRule(hit, evidence: evidence, source: settled, settings: settings)
            return
        }

        // Local filter runs before any bytes leave the machine.
        let verdict = SensitiveFilter.check(evidence, settings: settings)
        if verdict.isSensitive {
            journal.record(JournalEntry(
                originalPath: settled.path,
                filename: evidence.filename,
                outcome: .heldSensitive,
                reason: verdict.reason
            ))
            return
        }

        let root = DestinationRoot.root(for: settled, settings: settings)
        let classifier = Classifier(model: settings.model, routes: routes, root: root, settings: settings)
        let decision: Classifier.Decision
        do {
            decision = try await classifier.classify(evidence)
        } catch {
            recordFailure(error, path: settled.path, filename: evidence.filename)
            return
        }
        clearAPIError()

        // Settings as they are now, not as they were before a 45-second call:
        // dry run switched on mid-request must still stop the move.
        act(on: decision, evidence: evidence, source: settled,
            settings: settingsStore.settings, userInitiated: userInitiated)
    }

    /// A refusal is a decision; an outage is not. Only the first gets a journal
    /// line — a five-minute outage used to spend two attempts on every file and
    /// park them all for a day.
    private func recordFailure(_ error: Error, path: String, filename: String, isDirectory: Bool = false) {
        if case JevError.refusedSecret(let kind) = error {
            var e = JournalEntry(originalPath: path, filename: filename, outcome: .neverClassified,
                                 reason: "Refused before sending: looks like \(kind). Never sent, never moved.")
            e.isDirectory = isDirectory
            journal.record(e)
            return
        }
        lastError = Self.describe(error)
        if Self.isOutage(error) { apiUnavailable = true; return }
        var e = JournalEntry(originalPath: path, filename: filename, outcome: .failed, reason: Self.describe(error))
        e.isDirectory = isDirectory
        journal.record(e)
    }

    private func clearAPIError() {
        apiUnavailable = false
        if lastError != nil, lastError != Self.lockedMessage { lastError = nil }
    }

    nonisolated static func isOutage(_ error: Error) -> Bool {
        switch error {
        case JevError.missingKey: return true
        case JevError.http(let status, _): return [401, 403, 408, 429].contains(status) || (500...599).contains(status)
        case is URLError: return true
        default: return false
        }
    }

    /// What a person can act on, instead of a status code and a response body.
    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case JevError.missingKey:
            return "No API key yet. Add one in Settings → Privacy."
        case JevError.http(let status, _) where status == 401 || status == 403:
            return "The API key was rejected. Check it in Settings → Privacy."
        case JevError.http(let status, _) where status == 429:
            return "Too many requests. Usher will try again on the next pass."
        case JevError.http(let status, _) where (500...599).contains(status):
            return "The classification service is having trouble (\(status)). Usher will try again on the next pass."
        case let e as URLError where e.code == .notConnectedToInternet:
            return "No internet connection. Usher will try again on the next pass."
        case is URLError:
            return "Couldn't reach the classification service. Usher will try again on the next pass."
        default:
            return error.localizedDescription
        }
    }

    private func processUnit(_ dir: URL, settings: AppSettings) async {
        guard !FolderUnit.isExcluded(dir, settings: settings) else { return }
        let evidence = await Task.detached(priority: .utility) { EvidenceExtractor.extractUnit(from: dir) }.value
        let describe = "folder of \(evidence.fileCount ?? 0) files"
            + (evidence.dominantExtension.map { ", mostly .\($0)" } ?? "")

        var entry = JournalEntry(originalPath: dir.path, filename: dir.lastPathComponent,
                                 outcome: .pendingApproval, proposedName: dir.lastPathComponent)
        entry.isDirectory = true

        // Rules and the privacy filter see the folder exactly as they would a file.
        let root = DestinationRoot.root(for: dir, settings: settings)
        var destination: URL?
        if let hit = LocalRules.match(evidence, rules: rules) {
            destination = hit.rule.destinationURL(root: root)
            entry.routeKey = "rule:\(hit.rule.name)"; entry.routeProbability = 1; entry.routeConfidence = 1
            entry.reason = "\(describe) — matched rule \"\(hit.rule.name)\"; nothing sent."
        } else if SensitiveFilter.check(evidence, settings: settings).isSensitive {
            entry.outcome = .heldSensitive
            entry.reason = "\(describe) — looks personal; nothing sent."
            journal.record(entry); return
        } else {
            do {
                let decision = try await Classifier(model: settings.model, routes: routes, root: root, settings: settings).classify(evidence)
                entry.routeKey = decision.routeKey
                entry.routeProbability = decision.pathScore
                entry.routeConfidence = decision.routeConfidence
                entry.alternatives = topAlternatives(decision.probabilities)
                guard !decision.isUnsorted, let d = decision.destination else {
                    entry.outcome = .unsorted
                    entry.reason = "\(describe) — no folder matched."
                    journal.record(entry); return
                }
                destination = d
                entry.reason = String(format: "%@ — %.0f%%. Folders always ask.", describe, decision.pathScore * 100)
            } catch {
                recordFailure(error, path: dir.path, filename: dir.lastPathComponent, isDirectory: true)
                return
            }
        }

        if let destination {
            let plan = Mover.plan(source: dir, folder: destination, template: "{name}",
                                  chosenName: evidence.nameCandidates.first ?? dir.lastPathComponent,
                                  evidence: evidence)
            entry.proposedPath = plan.destination.path
            if Mover.isNoOp(plan) { entry.outcome = .alreadyFiled; entry.finalPath = plan.destination.path }
            else if settings.dryRun { entry.outcome = .dryRun }
        }
        journal.record(entry)
    }

    /// A rule match is certain, not probabilistic, so it skips the thresholds
    /// entirely. It still honours dry run, and it still never creates a folder that
    /// does not exist without asking.
    private func fileByRule(_ hit: RuleMatch,
                            evidence: Evidence,
                            source: URL,
                            settings: AppSettings) {

        let destination = hit.rule.destinationURL(root: DestinationRoot.root(for: source, settings: settings))
        let plan = Mover.plan(source: source,
                              folder: destination,
                              template: hit.rule.template ?? "{name}.{ext}",
                              chosenName: evidence.filename,
                              evidence: evidence)

        var entry = JournalEntry(
            originalPath: source.path,
            filename: evidence.filename,
            outcome: .dryRun,
            routeKey: "rule:\(hit.rule.name)",
            routeProbability: 1.0,
            routeConfidence: 1.0,
            proposedName: evidence.filename,
            proposedPath: plan.destination.path,
            reason: "Matched rule \"\(hit.rule.name)\" on \(hit.matchedOn) — never sent."
        )

        if Mover.isNoOp(plan) {
            entry.outcome = .alreadyFiled
            entry.finalPath = plan.destination.path
            entry.reason = "Already filed correctly."
            journal.record(entry)
            return
        }

        if case .duplicateOf(let existing) = Duplicates.check(source, against: destination) {
            handleDuplicate(existing: existing, source: source,
                            evidence: evidence, settings: settings, entry: &entry)
            journal.record(entry)
            return
        }

        // The folder existing is what separates "file it" from "invent a place".
        // Checked before dry run returns: a preview recorded without it looked
        // like an ordinary move, and turning dry run off then created the folder.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destination.path,
                                                   isDirectory: &isDirectory)
        if settings.dryRun {
            if !(exists && isDirectory.boolValue) {
                entry.createsFolder = true
                entry.proposedFolderName = destination.lastPathComponent
            }
            journal.record(entry)
            return
        }
        guard exists, isDirectory.boolValue else {
            entry.outcome = .pendingApproval
            entry.createsFolder = true
            entry.proposedFolderName = destination.lastPathComponent
            entry.reason = "Rule \"\(hit.rule.name)\" matched, but \(destination.lastPathComponent) does not exist yet."
            journal.record(entry)
            return
        }

        do {
            let final = try Mover.apply(plan)
            entry.outcome = .moved
            entry.finalPath = final.path
        } catch {
            entry.outcome = .failed
            entry.reason = error.localizedDescription
        }
        journal.record(entry)
    }

    /// Records a duplicate and, outside dry run, moves it to the duplicates folder
    /// so the original filing stays clean and nothing is destroyed.
    private func handleDuplicate(existing: URL,
                                 source: URL,
                                 evidence: Evidence,
                                 settings: AppSettings,
                                 entry: inout JournalEntry) {
        entry.outcome = .duplicate
        entry.duplicateOf = existing.path
        entry.reason = "Identical to \"\(existing.lastPathComponent)\" already filed there."

        guard !settings.dryRun, !settings.duplicatesFolder.isEmpty else { return }

        let folder = URL(fileURLWithPath:
            (settings.duplicatesFolder as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let plan = Mover.plan(source: source,
                                  folder: folder,
                                  template: "{name}.{ext}",
                                  chosenName: source.lastPathComponent,
                                  evidence: evidence)
            let final = try Mover.apply(plan, createFolders: true)
            entry.finalPath = final.path
            entry.reason = "Identical to \"\(existing.lastPathComponent)\" — set aside in Duplicates."
        } catch {
            entry.reason = "Duplicate of \"\(existing.lastPathComponent)\", "
                + "but could not set aside: \(error.localizedDescription)"
        }
    }

    // MARK: - Policy

    /// Thresholds are policy, kept out of the model and out of the classifier so
    /// they can change without re-running inference.
    private func act(on decision: Classifier.Decision,
                     evidence: Evidence,
                     source: URL,
                     settings: AppSettings,
                     userInitiated: Bool = false) {

        // You handed it over deliberately, so the bar to act is the ask-threshold
        // rather than the auto-move one. Folder creation is still never automatic.
        let moveThreshold = userInitiated
            ? settings.askThreshold
            : settings.autoMoveThreshold

        // pathScore, not routeProbability: a two-stage route has two chances to be
        // wrong and the threshold should see both.
        let score = decision.pathScore

        var entry = JournalEntry(
            originalPath: source.path,
            filename: evidence.filename,
            outcome: .lowConfidence,
            routeKey: decision.folderName.map { "\(decision.routeKey)/\($0)" } ?? decision.routeKey,
            routeProbability: score,
            routeConfidence: decision.routeConfidence,
            alternatives: topAlternatives(decision.probabilities),
            sensitiveByModel: decision.sensitiveByModel,
            proposedName: decision.chosenName,
            inputTokens: decision.usage?.input_tokens,
            outputTokens: decision.usage?.output_tokens
        )

        // Model-side backstop for anything the regex filter missed.
        if decision.sensitiveByModel >= 0.5 {
            entry.outcome = .heldSensitive
            entry.reason = String(format: "Jev read it as a personal record (%.0f%%)",
                                  decision.sensitiveByModel * 100)
            journal.record(entry)
            return
        }

        // No existing folder fits. Propose one and stop — creating directories is
        // never something the app decides on its own.
        if decision.needsNewFolder,
           let parent = decision.newFolderParent,
           let proposed = decision.proposedFolderName {
            let plan = Mover.plan(source: source,
                                  folder: parent.appendingPathComponent(proposed),
                                  template: decision.template,
                                  chosenName: decision.chosenName,
                                  evidence: evidence)
            entry.proposedPath = plan.destination.path
            entry.createsFolder = true
            entry.proposedFolderName = proposed
            entry.outcome = settings.dryRun ? .dryRun : .pendingApproval
            entry.reason = "No existing folder fits — would create \"\(proposed)\"."
            journal.record(entry)
            return
        }

        guard !decision.isUnsorted, let destination = decision.destination else {
            entry.outcome = .unsorted
            entry.reason = "No folder matched."
            journal.record(entry)
            return
        }

        let plan = Mover.plan(source: source,
                              folder: destination,
                              template: decision.template,
                              chosenName: decision.chosenName,
                              evidence: evidence)
        entry.proposedPath = plan.destination.path

        // A route whose folder is gone — renamed, or on a drive that is not
        // mounted — is a question, not a folder to create.
        var routeFolderIsDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: destination.path, isDirectory: &routeFolderIsDirectory)
            || !routeFolderIsDirectory.boolValue {
            entry.createsFolder = true
            entry.proposedFolderName = destination.lastPathComponent
            entry.outcome = settings.dryRun ? .dryRun : .pendingApproval
            entry.reason = "The folder \"\(destination.lastPathComponent)\" does not exist — creating it is your call."
            journal.record(entry)
            return
        }

        // Already where it belongs, under the name it should have. This is the
        // normal case when a destination folder is also watched, and it must be a
        // no-op — otherwise the move renames the file and fires another event.
        if Mover.isNoOp(plan) {
            entry.outcome = .alreadyFiled
            entry.finalPath = plan.destination.path
            entry.reason = "Already filed correctly."
            journal.record(entry)
            return
        }

        // Identical bytes already filed there. Setting this copy aside is the whole
        // point — filing it as "… 2" is how one folder ends up with four of these.
        if case .duplicateOf(let existing) = Duplicates.check(source, against: destination) {
            handleDuplicate(existing: existing, source: source,
                            evidence: evidence, settings: settings, entry: &entry)
            journal.record(entry)
            return
        }

        if settings.dryRun {
            entry.outcome = .dryRun
            entry.reason = "Dry run — nothing moved."
            journal.record(entry)
            return
        }

        if score >= moveThreshold {
            do {
                let final = try Mover.apply(plan)
                entry.outcome = .moved
                entry.finalPath = final.path
            } catch {
                entry.outcome = .failed
                entry.reason = error.localizedDescription
            }
        } else if score >= settings.askThreshold {
            entry.outcome = .pendingApproval
            entry.reason = "Below the auto-move threshold."
        } else {
            entry.outcome = .lowConfidence
            entry.reason = "Too uncertain to act."
        }

        journal.record(entry)
    }

    // MARK: - Manual actions

    /// Every pending proposal at once — except ones that would create a
    /// folder. A new folder is always asked about one at a time; "Move all"
    /// would otherwise have made `Memories/98d1d F5`, a name from an old bug,
    /// along with sixty sensible moves.
    func approveAll() {
        let batch = journal.pendingEntries.filter { !$0.createsFolder }
        Task {
            var moved: [UUID] = []
            for entry in batch where await self.approveNow(entry) { moved.append(entry.id) }
            if moved.count > 1 { self.lastBulkMove = moved }
        }
    }

    var approvableCount: Int { journal.pendingEntries.filter { !$0.createsFolder }.count }

    /// A failed file gets another go through the whole pipeline.
    func retry(_ entry: JournalEntry) {
        let url = URL(fileURLWithPath: entry.originalPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            var gone = entry
            gone.reason = "The file is no longer there."
            journal.update(gone)
            return
        }
        var cleared = entry; cleared.cleared = true; journal.update(cleared)
        enqueue([url], userInitiated: true)
    }

    func approve(_ entry: JournalEntry) {
        Task { await approveNow(entry) }
    }

    /// Returns whether the file moved.
    @discardableResult
    private func approveNow(_ entry: JournalEntry) async -> Bool {
        guard entry.outcome == .pendingApproval,
              let proposed = entry.proposedPath else { return false }
        var updated = entry
        // The floor again, at the moment of acting — name, format and content.
        // A proposal waits in the queue with the rules of the day it was made;
        // a Google client secret sat there with a Move button after the floor
        // learned what it was.
        let source = URL(fileURLWithPath: entry.originalPath)
        if let refusal = await refusal(for: source) {
            updated.outcome = .neverClassified
            updated.reason = "Not moved: \(refusal)."
            journal.update(updated)
            return false
        }
        do {
            // Approving a new-folder proposal is the one place a folder is made.
            let final = try Mover.apply(Mover.Plan(source: source, destination: URL(fileURLWithPath: proposed)),
                                        createFolders: entry.createsFolder)
            updated.outcome = .moved
            updated.finalPath = final.path
            updated.reason = "Approved by you."
            journal.update(updated)
            return true
        } catch {
            updated.outcome = .failed
            updated.reason = error.localizedDescription
            journal.update(updated)
            return false
        }
    }

    /// Bin the file a row is about, wherever it is now. Records a fresh entry
    /// so the original decision stays in the log; undo brings it back from the
    /// Trash to exactly where it was.
    func trash(_ entry: JournalEntry) {
        let path = entry.currentPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        var record = JournalEntry(timestamp: Date(), originalPath: path,
                                  filename: (path as NSString).lastPathComponent, outcome: .trashed)
        record.isDirectory = entry.isDirectory
        do {
            let binned = try Mover.trash(URL(fileURLWithPath: path))
            record.finalPath = binned.path
            record.reason = "Moved to the Trash from \(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent)."
            // Only now: a failed trash used to remove the row it came from and
            // leave nothing but "could not trash".
            var previous = entry; previous.cleared = true; journal.update(previous)
        } catch {
            record.outcome = .failed
            record.routeKey = "trash"   // so the row offers no Retry: Retry refiles, it does not trash
            record.reason = "Could not trash: \(error.localizedDescription)"
        }
        journal.record(record)
    }

    func undo(_ entry: JournalEntry) {
        guard let finalPath = entry.finalPath else { return }
        var updated = entry
        do {
            let back = URL(fileURLWithPath: entry.originalPath)
            recentlyUndone.insert(back.canonicalPath)
            // Belt and braces: the FSEvent can arrive after a delay, or twice.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.recentlyUndone.remove(back.canonicalPath)
            }
            _ = try Mover.undo(from: URL(fileURLWithPath: finalPath), to: back)
            updated.undone = true
            updated.reason = entry.outcome == .trashed ? "Back from the Trash." : "Undone — put back."
        } catch {
            updated.reason = "Undo failed: \(error.localizedDescription)"
        }
        journal.update(updated)
    }

    /// Run the pipeline over a folder's existing contents, for testing against
    /// files that are already sitting there.
    func sweep(folder: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        enqueue(contents.filter { $0.hasDirectoryPath == false })
    }

    private func topAlternatives(_ probabilities: [String: Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues:
            probabilities.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, $0.value) })
    }
}
