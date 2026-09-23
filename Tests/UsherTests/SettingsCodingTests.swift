import XCTest
import CryptoKit
@testable import Usher

/// Swift's synthesized Codable ignores property defaults and throws on a missing
/// key. Adding one setting therefore broke every existing settings.json, and the
/// failure path wrote defaults back over the file — silently destroying watch
/// folders and tuned privacy patterns.
final class SettingsCodingTests: XCTestCase {

    func testDecodesConfigWrittenBeforeNewKeysExisted() throws {
        // Deliberately missing duplicatesFolder, keepPanelOpen, maxCloudDownloadMB…
        let legacy = """
        {
          "watchFolders": [
            {"id":"6C7E1B1E-0000-0000-0000-000000000001","path":"/Users/x/Downloads",
             "enabled":true,"recursive":false}
          ],
          "dryRun": true,
          "autoMoveThreshold": 0.8,
          "askThreshold": 0.45,
          "model": "jev-latest",
          "sensitivePatterns": ["bank","lic "],
          "sensitiveHosts": ["hdfc"]
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))

        XCTAssertEqual(decoded.watchFolders.count, 1)
        XCTAssertEqual(decoded.sensitivePatterns, ["bank", "lic "])
        XCTAssertEqual(decoded.sensitiveHosts, ["hdfc"])
        // Absent keys fall back rather than failing the whole decode.
        XCTAssertEqual(decoded.keepPanelOpen, AppSettings.default.keepPanelOpen)
        XCTAssertEqual(decoded.duplicatesFolder, AppSettings.default.duplicatesFolder)
    }

    func testWatchFolderToleratesMissingOptionalFields() throws {
        let minimal = #"{"path":"/Users/x/Desktop"}"#
        let folder = try JSONDecoder().decode(WatchFolder.self, from: Data(minimal.utf8))
        XCTAssertEqual(folder.path, "/Users/x/Desktop")
        XCTAssertTrue(folder.enabled)
        XCTAssertFalse(folder.recursive)
    }

    func testRoundTripPreservesEverything() throws {
        var original = AppSettings.default
        original.sensitivePatterns = ["custom"]
        original.keepPanelOpen = false
        original.maxCloudDownloadMB = 42

        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back.sensitivePatterns, ["custom"])
        XCTAssertFalse(back.keepPanelOpen)
        XCTAssertEqual(back.maxCloudDownloadMB, 42)
    }
}

extension SettingsCodingTests {
    /// A journal line written before `cleared`, `createsFolder` or `undone`
    /// existed must still load — Journal.load drops any line that throws, so the
    /// alternative is the whole history vanishing from the panel.
    func testOldJournalLinesStillDecode() throws {
        let old = #"{"id":"6C7E1B1E-0000-0000-0000-000000000009","timestamp":"2026-09-18T20:00:00Z","originalPath":"/x/a.pdf","filename":"a.pdf","outcome":"moved","finalPath":"/y/a.pdf"}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let e = try d.decode(JournalEntry.self, from: Data(old.utf8))
        XCTAssertFalse(e.cleared); XCTAssertFalse(e.undone); XCTAssertFalse(e.createsFolder)
        XCTAssertTrue(e.canUndo)
        XCTAssertTrue(e.isClearable)
    }
}

@MainActor
final class CatchUpPolicyTests: XCTestCase {
    /// Never the real journal: an earlier version of these tests appended fake
    /// decisions to it and then read them back on the next run.
    private func fresh() -> Journal {
        Journal(file: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-test-\(UUID()).ndjson"), key: .test)
    }
    private func entry(_ path: String, _ outcome: Outcome, ageHours: Double = 0, with: String? = "fp-A") -> JournalEntry {
        var e = JournalEntry(timestamp: Date().addingTimeInterval(-ageHours * 3600),
                             originalPath: path, filename: (path as NSString).lastPathComponent, outcome: outcome)
        e.decidedWith = with
        return e
    }

    func testFinalOutcomesAreNeverRevisited() {
        let j = fresh()
        j.record(entry("/x/moved.pdf", .moved));            XCTAssertFalse(j.needsDecision("/x/moved.pdf", fingerprint: "fp-A"))
        j.record(entry("/x/wait.pdf", .pendingApproval));   XCTAssertFalse(j.needsDecision("/x/wait.pdf", fingerprint: "fp-B"))
        j.record(entry("/x/vault.kdbx", .neverClassified)); XCTAssertFalse(j.needsDecision("/x/vault.kdbx", fingerprint: "fp-A"))
        // A changed floor is re-applied. The re-check stops at the name, before
        // anything is opened — a vault is floored again, an invoice the old
        // content check mistook for recovery codes gets its hold back.
        XCTAssertTrue(j.needsDecision("/x/vault.kdbx", fingerprint: "fp-B"))
        XCTAssertTrue(j.needsDecision("/x/never-seen.pdf", fingerprint: "fp-A"))
    }

    /// The readers for Word files shipped after a pass marked twenty files
    /// "no folder matched" on their names alone. A changed app is reason enough
    /// to look again — not a 24-hour wait.
    func testChangedAppOrConfigTriggersAnotherLook() {
        let j = fresh()
        j.record(entry("/x/doc.docx", .unsorted, with: "fp-A"))
        XCTAssertTrue(j.needsDecision("/x/doc.docx", fingerprint: "fp-A"), "same fingerprint, first attempt: one more look")
        XCTAssertTrue(j.needsDecision("/x/doc.docx", fingerprint: "fp-B"), "different fingerprint: revisit")
    }

    /// Same app, same config: one more pass, then stop until a day has gone.
    func testAtMostTwoPassesPerFingerprint() {
        let j = fresh()
        j.record(entry("/x/a.pdf", .unsorted, with: "fp-A"))
        XCTAssertTrue(j.needsDecision("/x/a.pdf", fingerprint: "fp-A"), "second look allowed")
        j.record(entry("/x/a.pdf", .unsorted, with: "fp-A"))       // attempt becomes 2
        XCTAssertFalse(j.needsDecision("/x/a.pdf", fingerprint: "fp-A"), "third look within a day: no")
        j.record(entry("/x/a.pdf", .unsorted, ageHours: 30, with: "fp-A"))
        XCTAssertTrue(j.needsDecision("/x/a.pdf", fingerprint: "fp-A"), "a day later: yes")
    }

    func testHeldFilesFollowTheSameRule() {
        let j = fresh()
        j.record(entry("/x/held.pdf", .heldSensitive, with: "fp-A"))
        j.record(entry("/x/held.pdf", .heldSensitive, with: "fp-A"))
        XCTAssertFalse(j.needsDecision("/x/held.pdf", fingerprint: "fp-A"))
        XCTAssertTrue(j.needsDecision("/x/held.pdf", fingerprint: "fp-B"), "a new rule may file it now — re-checked locally")
    }
}

@MainActor
final class PanelDecisionTests: XCTestCase {
    private func fresh() -> Journal {
        Journal(file: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-test-\(UUID()).ndjson"), key: .test)
    }
    private func entry(_ path: String, _ outcome: Outcome) -> JournalEntry {
        JournalEntry(timestamp: Date(), originalPath: path,
                     filename: (path as NSString).lastPathComponent, outcome: outcome)
    }

    /// "Leave" on a proposal: the file stays, the row and the badge count both
    /// drop it, and the pipeline still treats the path as decided.
    func testLeavingAProposalDropsItFromTheCountWithoutMoving() throws {
        // Real paths: the panel hides rows whose file is gone, so a fake
        // /x/ path would be filtered out for the wrong reason.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-leave-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("Berkeley Mono"), b = dir.appendingPathComponent("TaxHacker-main")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)

        let j = fresh()
        j.record(entry(a.path, .pendingApproval))
        j.record(entry(b.path, .pendingApproval))
        XCTAssertEqual(j.pendingCount, 2)
        j.decline(j.pendingEntries.first { $0.originalPath == a.path }!)
        XCTAssertEqual(j.pendingCount, 1)
        XCTAssertEqual(j.visible.count, 1)
        XCTAssertFalse(j.needsDecision(a.path, fingerprint: "fp-A"), "left in place is a decision")
    }

    /// A failure used to be the one row you could never dismiss.
    func testFailedRowsAreClearable() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-broken-\(UUID()).pdf")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let j = fresh()
        j.record(entry(file.path, .failed))
        XCTAssertEqual(j.clearableCount, 1)
        j.clearDone()
        XCTAssertTrue(j.visible.isEmpty)
    }
}

@MainActor
final class PanelClearTests: XCTestCase {
    private func fresh() -> Journal {
        Journal(file: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-test-\(UUID()).ndjson"), key: .test)
    }

    /// Clearing must clear the backlog too. The panel holds 300 rows in memory
    /// while the file held 5,500 — clearing the 300 just uncovered the next 300
    /// on the next launch, all of them from a folder no longer watched.
    func testClearingHidesOlderRowsThatWereNeverLoaded() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-test-\(UUID()).ndjson")
        let here = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-live-\(UUID()).txt")
        try Data("x".utf8).write(to: here)
        defer { try? FileManager.default.removeItem(at: here) }

        let first = Journal(file: file, key: .test)
        var old = JournalEntry(timestamp: Date().addingTimeInterval(-3600), originalPath: here.path,
                               filename: here.lastPathComponent, outcome: .unsorted)
        old.id = UUID()
        first.record(old)
        var waiting = JournalEntry(timestamp: Date().addingTimeInterval(-3600), originalPath: here.path + ".2",
                                   filename: "waiting.pdf", outcome: .pendingApproval)
        waiting.finalPath = here.path      // something that exists, so it is not a dead row
        first.record(waiting)
        first.clearDone()

        let reopened = Journal(file: file, key: .test)
        XCTAssertFalse(reopened.visible.contains { $0.outcome == .unsorted }, "old decision stays cleared across launches")
        XCTAssertTrue(reopened.visible.contains { $0.outcome == .pendingApproval }, "a proposal waiting on you survives Clear")
    }

    /// A row whose file was deleted in Finder has nothing behind any of its buttons.
    func testRowsForVanishedFilesAreNotShown() {
        let j = fresh()
        j.record(JournalEntry(timestamp: Date(), originalPath: "/x/gone.pdf",
                              filename: "gone.pdf", outcome: .unsorted))
        XCTAssertTrue(j.visible.isEmpty)
    }
}

@MainActor
final class AnsweredVersusUnansweredTests: XCTestCase {
    private func fresh() -> Journal {
        Journal(file: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-test-\(UUID()).ndjson"), key: .test)
    }
    private func entry(_ path: String, _ outcome: Outcome, p: Double?, ageHours: Double = 0) -> JournalEntry {
        var e = JournalEntry(timestamp: Date().addingTimeInterval(-ageHours * 3600), originalPath: path,
                             filename: (path as NSString).lastPathComponent, outcome: outcome)
        e.routeProbability = p
        e.decidedWith = "fp-A"
        return e
    }

    /// Jev answered "no folder fits". Asking again with the same routes and the
    /// same logic buys the same answer — every day, forever, at a call each.
    func testAnAnswerIsNotReAskedUntilSomethingThatCouldChangeItChanges() {
        let j = fresh()
        j.record(entry("/x/a.pdf", .unsorted, p: 0.81, ageHours: 48))
        j.record(entry("/x/b.pdf", .lowConfidence, p: 0.31, ageHours: 48))
        j.record(entry("/x/c.pdf", .dryRun, p: 0.92, ageHours: 48))
        for path in ["/x/a.pdf", "/x/b.pdf", "/x/c.pdf"] {
            XCTAssertFalse(j.needsDecision(path, fingerprint: "fp-A"), "\(path): same routes, same answer")
            XCTAssertTrue(j.needsDecision(path, fingerprint: "fp-B"), "\(path): routes changed, ask again")
        }
    }

    /// A placeholder that would not download was recorded as lowConfidence with
    /// no probability. That is a network hiccup, not a judgment — retry it.
    func testNoProbabilityMeansNoAnswerAndIsRetried() {
        let j = fresh()
        j.record(entry("/x/cloud.pdf", .lowConfidence, p: nil))
        XCTAssertTrue(j.needsDecision("/x/cloud.pdf", fingerprint: "fp-A"), "second look for a hiccup")
    }
}

final class PolicyOutcomeTests: XCTestCase {
    /// Thresholds are applied to the stored answer, so this is the whole of
    /// what changes when you move a threshold — no call to Jev involved.
    func testThresholdsDecideFromTheStoredProbability() {
        let o = { (p: Double, folder: Bool) in
            Pipeline.policyOutcome(probability: p, createsFolder: folder, auto: 0.8, ask: 0.45)
        }
        XCTAssertEqual(o(0.9, false), .moved)
        XCTAssertEqual(o(0.6, false), .pendingApproval)
        XCTAssertEqual(o(0.2, false), .lowConfidence)
        XCTAssertEqual(o(0.99, true), .pendingApproval, "creating a folder is never automatic")
    }

    /// Turning dry run off used to change the fingerprint and re-send every
    /// file ever previewed. Policy must not be part of it.
    func testPolicyIsNotPartOfTheFingerprintSource() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Usher/Core/ConfigFingerprint.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined()
        XCTAssertFalse(code.contains("dryRun"))
        XCTAssertFalse(code.contains("Threshold"))
        XCTAssertFalse(code.contains("modificationDate"), "a rebuild is not a reason to ask again")
    }
}

@MainActor
final class HeldByModelTests: XCTestCase {
    /// Jev called it a personal record. Sending it again tomorrow to ask the
    /// same question is the leak the hold exists to prevent.
    func testAFileJevHeldAsPersonalIsNotSentAgain() {
        let j = Journal(file: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-held-\(UUID()).ndjson"), key: .test)
        var e = JournalEntry(timestamp: Date().addingTimeInterval(-72 * 3600), originalPath: "/x/statement.pdf",
                             filename: "statement.pdf", outcome: .heldSensitive)
        e.routeProbability = 0.9
        e.decidedWith = "fp-A"
        j.record(e)
        XCTAssertFalse(j.needsDecision("/x/statement.pdf", fingerprint: "fp-A"), "not again, not tomorrow, not in a week")
    }
}
