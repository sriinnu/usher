import XCTest
import CryptoKit
@testable import Usher

/// One test per finding from the 2026-09-22 code review that could be pinned
/// in isolation. Each comment says what actually went wrong.
final class ReviewRegressionTests: XCTestCase {

    // A byte cap that lands inside "ü" made String(data:encoding:) return nil for
    // the whole excerpt, so a German bank letter reached the filter with no text.
    func testTextCutMidCharacterStillDecodes() {
        var bytes = Data("Kontoauszug für ".utf8)
        bytes.append(contentsOf: [0xC3])                    // first byte of "ü", cut here
        let text = EvidenceExtractor.decodeText(bytes)
        XCTAssertEqual(text, "Kontoauszug für ")
        XCTAssertNil(String(data: bytes, encoding: .utf8), "sanity: plain decoding fails on this input")
    }

    // "zlib" and "libgen" are also real software; stripping them bare renamed
    // zlib-1.3.1.tar.gz to 1.3.1.tar.gz on its way into the Software folder.
    func testSoftwareNamesAreNotMirrorMarkers() {
        XCTAssertNil(BookName.stripped(for: "zlib-1.3.1.tar.gz"))
        XCTAssertNil(BookName.stripped(for: "libgen-tools.zip"))
        XCTAssertNil(BookName.stripped(for: "openlibrary-export-2024.json"))
        XCTAssertEqual(BookName.stripped(for: "Some Book (libgen).pdf"), "Some Book.pdf")
        XCTAssertEqual(BookName.stripped(for: "Some Book - libgen.pdf"), "Some Book.pdf")
        XCTAssertEqual(BookName.stripped(for: "Some Book (Z-Library).pdf"), "Some Book.pdf")
    }

    // Requiring size > 0 made a zero-byte file poll for the full five minutes.
    func testEmptyFileSettles() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-empty-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("empty.txt")
        try Data().write(to: f)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: f.path)
        let started = Date()
        let settled = await StabilityGate.waitUntilStable(f, pollInterval: 0.1, stableReadsRequired: 2, timeout: 10)
        XCTAssertNotNil(settled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // An API answer with no `choice` decodes as "", and "" appended to a parent
    // is the parent; the placeholder criterion was becoming a real folder.
    func testUnusableFolderNamesAreRefused() {
        XCTAssertNil(Classifier.usableFolderName(""))
        XCTAssertNil(Classifier.usableFolderName("   "))
        XCTAssertNil(Classifier.usableFolderName("Unsorted"))
        XCTAssertNil(Classifier.usableFolderName("a/b"))
        XCTAssertEqual(Classifier.usableFolderName(" Alia Bhatt "), "Alia Bhatt")
    }

    // A tool that produces nothing blocked the extraction slot forever: the
    // deadline was only checked between reads.
    func testStuckToolIsKilledAtTheDeadline() {
        let started = Date()
        let out = EvidenceExtractor.run("/bin/sleep", ["30"], limit: 1024, timeout: 1)
        XCTAssertNil(out)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // A unit must never be a folder that routes depend on.
    func testRouteDestinationsAreProtectedFromUnitMoves() {
        let protectedPaths = Pipeline.protectedPaths(settings: .default, rules: [], table: .load())
        let dup = URL(fileURLWithPath: (AppSettings.default.duplicatesFolder as NSString).expandingTildeInPath).canonicalPath
        XCTAssertTrue(protectedPaths.contains(dup))
    }
}

@MainActor
final class ReviewCatchUpPolicyTests: XCTestCase {
    private func fresh() -> Journal {
        Journal(file: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-rr-\(UUID()).ndjson"), key: .test)
    }
    private func entry(_ path: String, _ outcome: Outcome, with: String, undone: Bool = false) -> JournalEntry {
        var e = JournalEntry(originalPath: path, filename: "f", outcome: outcome)
        e.decidedWith = with; e.undone = undone; e.finalPath = "/y/f"
        return e
    }

    // Dry run re-sent every previewed file every thirty minutes.
    func testPreviewedFilesAreNotReSentForever() {
        let j = fresh()
        j.record(entry("/x/a.pdf", .dryRun, with: "A"))
        XCTAssertTrue(j.needsDecision("/x/a.pdf", fingerprint: "A"), "one more look")
        j.record(entry("/x/a.pdf", .dryRun, with: "A"))
        XCTAssertFalse(j.needsDecision("/x/a.pdf", fingerprint: "A"), "not a third within a day")
        XCTAssertTrue(j.needsDecision("/x/a.pdf", fingerprint: "B"), "turning dry run off changes the fingerprint")
    }

    // An undone move is a labelled miss: left alone until something changes.
    func testUndoneMoveIsLeftAloneUntilConfigChanges() {
        let j = fresh()
        j.record(entry("/x/b.pdf", .moved, with: "A", undone: true))
        XCTAssertFalse(j.needsDecision("/x/b.pdf", fingerprint: "A"))
        XCTAssertTrue(j.needsDecision("/x/b.pdf", fingerprint: "B"))
    }
}

final class LegendTests: XCTestCase {
    /// The legend is the only explanation of what a row means. A new outcome
    /// with no entry would show up in the panel as a word nobody defined.
    func testEveryOutcomeIsExplainedInTheLegend() {
        let explained = Set(Legend.outcomes.map(\.name))
        for outcome in Outcome.allCases {
            XCTAssertTrue(explained.contains(outcome.shortLabel),
                          "\(outcome.rawValue) has no legend entry")
            XCTAssertFalse(outcome.explanation.isEmpty, "\(outcome.rawValue) has no explanation")
        }
    }
}
