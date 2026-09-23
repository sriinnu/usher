import Foundation
import CryptoKit

enum Outcome: String, Codable, CaseIterable {
    case moved              // file relocated
    case dryRun             // decision made, file untouched (dry-run mode)
    case lowConfidence      // below askThreshold, left in place
    case pendingApproval    // between thresholds, waiting on you
    case unsorted           // Jev picked the no-match option
    case heldSensitive      // never sent to the API
    case alreadyFiled       // right folder, right name — nothing to do
    case duplicate          // identical bytes already filed there
    case neverClassified    // password vault, key, wallet — untouched by design
    case failed
    case trashed            // you binned it from the panel; finalPath is the Trash copy
}

struct JournalEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var originalPath: String
    var filename: String
    var outcome: Outcome

    var routeKey: String?
    var routeProbability: Double?
    var routeConfidence: Double?
    /// Top few alternatives, kept for calibration later.
    var alternatives: [String: Double]?
    var sensitiveByModel: Double?

    var proposedName: String?
    var proposedPath: String?
    var finalPath: String?
    /// Set when acting would create a folder that does not exist yet. Always
    /// requires approval — the app never creates one on its own.
    var createsFolder: Bool = false
    /// Path of the copy already filed, when this file is a duplicate.
    var duplicateOf: String?
    var proposedFolderName: String?

    var reason: String?
    var inputTokens: Int?
    var outputTokens: Int?
    /// Set when you undo a move, so the record survives as a labeled miss.
    var undone: Bool = false
    /// Dismissed from the panel. The journal file keeps the line; only the
    /// menubar view stops showing it.
    var cleared: Bool = false
    /// Fingerprint of the app + config that made this decision, and which
    /// attempt this was for the path. Catch-up uses both to decide whether a
    /// no-match deserves another look.
    var decidedWith: String?
    var attempt: Int = 1
    /// The entry is a whole folder filed as one unit.
    var isDirectory: Bool = false
    /// Which file this was (creation date and size), so a new file at an old
    /// path is not mistaken for the one already decided.
    var fileIdentity: String?

    var canUndo: Bool { (outcome == .moved || outcome == .trashed) && !undone && finalPath != nil }

    /// Where the file is right now, as far as the journal knows.
    var currentPath: String {
        if undone { return originalPath }
        return finalPath ?? originalPath
    }

    /// Anything but a proposal still waiting on an answer — failures included:
    /// a row you cannot dismiss is a row that never leaves.
    var isClearable: Bool { outcome != .pendingApproval }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, originalPath, filename, outcome
        case routeKey, routeProbability, routeConfidence, alternatives, sensitiveByModel
        case proposedName, proposedPath, finalPath, createsFolder, duplicateOf, proposedFolderName
        case reason, inputTokens, outputTokens, undone, cleared, decidedWith, attempt, isDirectory
        case fileIdentity
    }
}

/// Synthesized Codable throws on a missing key even when the property has a
/// default, and Journal.load swallows the throw per line — so every journal
/// entry written before a field existed would silently vanish from the panel
/// the moment that field was added. Booleans with defaults decode leniently.
extension JournalEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        originalPath = try c.decode(String.self, forKey: .originalPath)
        filename = try c.decode(String.self, forKey: .filename)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        routeKey = try c.decodeIfPresent(String.self, forKey: .routeKey)
        routeProbability = try c.decodeIfPresent(Double.self, forKey: .routeProbability)
        routeConfidence = try c.decodeIfPresent(Double.self, forKey: .routeConfidence)
        alternatives = try c.decodeIfPresent([String: Double].self, forKey: .alternatives)
        sensitiveByModel = try c.decodeIfPresent(Double.self, forKey: .sensitiveByModel)
        proposedName = try c.decodeIfPresent(String.self, forKey: .proposedName)
        proposedPath = try c.decodeIfPresent(String.self, forKey: .proposedPath)
        finalPath = try c.decodeIfPresent(String.self, forKey: .finalPath)
        createsFolder = (try? c.decodeIfPresent(Bool.self, forKey: .createsFolder)) ?? false
        duplicateOf = try c.decodeIfPresent(String.self, forKey: .duplicateOf)
        proposedFolderName = try c.decodeIfPresent(String.self, forKey: .proposedFolderName)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
        undone = (try? c.decodeIfPresent(Bool.self, forKey: .undone)) ?? false
        cleared = (try? c.decodeIfPresent(Bool.self, forKey: .cleared)) ?? false
        decidedWith = try c.decodeIfPresent(String.self, forKey: .decidedWith)
        attempt = (try? c.decodeIfPresent(Int.self, forKey: .attempt)) ?? 1
        isDirectory = (try? c.decodeIfPresent(Bool.self, forKey: .isDirectory)) ?? false
        fileIdentity = try? c.decodeIfPresent(String.self, forKey: .fileIdentity)
    }
}

/// Append-only NDJSON. Every decision is recorded, including the ones where
/// nothing happened — those are the interesting ones when tuning thresholds.
@MainActor
final class Journal: ObservableObject {

    @Published private(set) var entries: [JournalEntry] = []
    private let maxInMemory = 300

    /// The latest entry per original path, over the WHOLE file — the in-memory
    /// list is capped, and catch-up must not re-send a file that was decided
    /// three thousand lines ago. Whole entries, not a summary: re-applying a
    /// changed threshold needs the stored answer, not just its outcome.
    private(set) var latest: [String: JournalEntry] = [:]

    /// A second look is allowed with an unchanged app and config — it catches a
    /// placeholder that timed out or an API hiccup — but not a third: the same
    /// evidence through the same app gives the same answer.
    static let maxAttemptsPerFingerprint = 2

    /// The file this journal reads and appends to. Injectable so tests use a
    /// temporary file — a test suite that appended fake decisions to the real
    /// journal was polluting catch-up's memory of what had been decided.
    let file: URL

    /// Everything decided at or before this is off the panel, whatever the
    /// journal lines say. One timestamp in a sidecar file instead of five
    /// thousand `cleared: true` lines appended to the record — the journal is
    /// the calibration set, and dismissing a row from a panel is not a label.
    private(set) var clearedBefore: Date?
    private var watermarkFile: URL { file.deletingPathExtension().appendingPathExtension("cleared") }

    /// Encrypts every line. Nil means the key exists but could not be read.
    private let key: SymmetricKey?

    /// The journal could not be unlocked. Nothing is read or written, and the
    /// pipeline refuses to start: an empty journal would mean deciding — and
    /// sending — every file again.
    var isLocked: Bool { key == nil }

    init(file: URL = Paths.journal, key: SymmetricKey? = LogCipher.key()) {
        self.file = file
        self.key = key
        clearedBefore = (try? String(contentsOf: watermarkFile, encoding: .utf8))
            .flatMap { ISO8601DateFormatter().date(from: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        load()
    }

    /// Whether catch-up should look at this path (again).
    ///
    /// Never seen: yes. Moved, waiting on you, a duplicate, already in place,
    /// binned, or never-classified: no.
    ///
    /// For the rest, the question is whether Jev actually answered. An answer
    /// carries a probability, and the same evidence through the same logic
    /// gives the same answer — so it is asked again only when something that
    /// could change it changed (the fingerprint). Thresholds and dry run are
    /// not in that list: they are re-applied to the stored answer locally.
    ///
    /// No probability means no answer: a placeholder that would not download,
    /// an API hiccup, a failure, or a hold (checked here, never sent). Those
    /// get a second look, then one a day.
    func needsDecision(_ path: String, now: Date = Date(),
                       fingerprint: String = ConfigFingerprint.current,
                       identity: String? = nil) -> Bool {
        guard let last = latest[path] else { return true }
        // A different file now sits at this path. Whatever was decided about
        // the old one says nothing about this one.
        if let identity, let before = last.fileIdentity, identity != before { return true }
        switch last.outcome {
        case .moved:
            // An undone move is a labelled miss: leave the file alone until the
            // app or config changes, then it may deserve a fresh look.
            return last.undone && last.decidedWith != fingerprint
        case .trashed:
            // Binned by hand. If it came back from the Trash, that was also by
            // hand — a sweep has no business re-filing it.
            return false
        case .neverClassified:
            // The floor is checked here, before anything is read or sent, so a
            // second check is free. When the floor changes it is re-applied:
            // three invoices a first content check floored as "recovery codes"
            // would otherwise have stayed floored for good.
            return last.decidedWith != fingerprint
        case .pendingApproval, .duplicate, .alreadyFiled:
            return false
        case .dryRun where last.routeProbability != nil,
             .unsorted where last.routeProbability != nil,
             .lowConfidence where last.routeProbability != nil,
             // Held *by Jev* — it read the excerpt and called it a personal
             // record. That hold carries a probability. Left in the retry
             // branch below, the same personal record was sent again the next
             // sweep and once a day after that: the one outcome that exists to
             // stop sending was the one that kept sending.
             .heldSensitive where last.routeProbability != nil:
            return last.decidedWith != fingerprint
        case .dryRun, .failed, .heldSensitive, .unsorted, .lowConfidence:
            if last.decidedWith != fingerprint { return true }
            if last.attempt < Self.maxAttemptsPerFingerprint { return true }
            return now.timeIntervalSince(last.timestamp) > 24 * 3600
        }
    }

    /// Decisions Jev already made whose outcome depends on policy — dry run and
    /// the two thresholds — for files still where they were found. Folder
    /// units and anything you told to stay are left out.
    func redecidable(in folders: [URL]) -> [JournalEntry] {
        let roots = folders.map { $0.standardizedFileURL.path }
        return latest.values.filter { e in
            guard [.dryRun, .lowConfidence, .pendingApproval].contains(e.outcome),
                  e.routeProbability != nil, e.proposedPath != nil,
                  !e.isDirectory, !e.undone else { return false }
            if e.outcome == .pendingApproval && e.cleared { return false }   // "Leave"
            guard roots.contains(where: { e.originalPath == $0 || e.originalPath.hasPrefix($0 + "/") })
            else { return false }
            return FileManager.default.fileExists(atPath: e.originalPath)
        }
    }

    /// Stamps an entry with the current fingerprint and its attempt number for
    /// the path. Every record goes through here, so the pipeline never has to.
    private func stamped(_ entry: JournalEntry) -> JournalEntry {
        var e = entry
        if e.decidedWith == nil { e.decidedWith = ConfigFingerprint.current }
        // Read where the file is now: a move keeps creation date and size.
        if e.fileIdentity == nil {
            e.fileIdentity = FileIdentity.of(URL(fileURLWithPath: e.finalPath ?? e.originalPath))
                ?? FileIdentity.of(URL(fileURLWithPath: e.originalPath))
        }
        if let prev = latest[e.originalPath], prev.decidedWith == e.decidedWith {
            e.attempt = max(e.attempt, prev.attempt + 1)
        }
        return e
    }

    func record(_ entry: JournalEntry) {
        let entry = stamped(entry)
        latest[entry.originalPath] = entry
        entries.insert(entry, at: 0)
        if entries.count > maxInMemory { entries.removeLast(entries.count - maxInMemory) }
        append(entry)
    }

    func update(_ entry: JournalEntry) {
        latest[entry.originalPath] = entry
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        }
        append(entry)   // a later line for the same id supersedes the earlier one
    }

    /// Pending rows the user has not dismissed with "Leave".
    var pendingCount: Int {
        entries.filter { $0.outcome == .pendingApproval && !$0.cleared }.count
    }

    var pendingEntries: [JournalEntry] {
        entries.filter { $0.outcome == .pendingApproval && !$0.cleared }
    }

    /// "Leave it": the proposal stays on record, nothing moves, the row and the
    /// count both drop it. The file is left exactly where it is.
    func decline(_ entry: JournalEntry) {
        var e = entry
        e.cleared = true
        e.reason = [e.reason, "Left in place."].compactMap { $0 }.joined(separator: " ")
        update(e)
    }

    /// What the panel shows: everything not yet dismissed, and still about a
    /// file that exists. A row for a file you deleted in Finder three days ago
    /// offers nothing — every button on it fails.
    var visible: [JournalEntry] {
        entries.filter { !isDismissed($0) && !isDead($0) }
    }

    /// A decision the panel has no reason to show again.
    private func isDismissed(_ entry: JournalEntry) -> Bool {
        if entry.cleared { return true }
        // A proposal still waiting on you survives the watermark: "clear the
        // panel" must never silently decline sixty-five folder moves.
        guard entry.outcome != .pendingApproval, let before = clearedBefore else { return false }
        return entry.timestamp <= before
    }

    private func isDead(_ entry: JournalEntry) -> Bool {
        let fm = FileManager.default
        if let final = entry.finalPath, fm.fileExists(atPath: final) { return false }
        return !fm.fileExists(atPath: entry.originalPath)
    }

    var clearableCount: Int {
        visible.filter(\.isClearable).count
    }

    /// Dismisses every handled entry from the panel. Each becomes a new journal
    /// line with `cleared: true`; nothing is removed from the file, and undo stays
    /// reachable under the panel's "Cleared" filter.
    func clearDone() {
        // The watermark does the work for everything older than this moment,
        // including the thousands of lines the in-memory list never held.
        // Without it, clearing 300 rows just uncovered the next 300.
        let now = Date()
        clearedBefore = now
        try? ISO8601DateFormatter().string(from: now)
            .write(to: watermarkFile, atomically: true, encoding: .utf8)

        // Loaded rows are still stamped individually, so the Cleared filter can
        // find them and undo stays reachable.
        for entry in entries where !entry.cleared && entry.isClearable {
            var updated = entry
            updated.cleared = true
            update(updated)
        }
        objectWillChange.send()
    }

    private func append(_ entry: JournalEntry) {
        // Locked means nothing in the clear, ever — not "write it plain for now".
        guard let key else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        LogCipher.append(data, to: file, key: key)
    }

    private func load() {
        guard let key else { return }
        // A journal from before encryption is sealed line by line on first
        // open, and replaced only once every line reads back.
        LogCipher.migrate(file, key: key)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Later lines win, so replay forward into a dictionary keyed by id.
        var byID: [UUID: JournalEntry] = [:]
        var order: [UUID] = []
        for data in LogCipher.readLines(file, key: key) {
            guard let entry = try? decoder.decode(JournalEntry.self, from: data) else { continue }
            if byID[entry.id] == nil { order.append(entry.id) }
            byID[entry.id] = entry
            // Later lines win here too, so this ends up as each path's last word.
            latest[entry.originalPath] = entry
        }
        entries = order.reversed().compactMap { byID[$0] }
        if entries.count > maxInMemory { entries.removeLast(entries.count - maxInMemory) }
    }
}
