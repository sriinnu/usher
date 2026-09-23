import XCTest
import CryptoKit
@testable import Usher

@MainActor
final class LogCipherTests: XCTestCase {
    private func temp(_ name: String = "log") -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-\(name)-\(UUID()).ndjson")
    }

    /// The point of all this: no filename, path or reason readable on disk.
    func testNothingInTheJournalFileIsReadable() throws {
        let file = temp()
        let j = Journal(file: file, key: .test)
        j.record(JournalEntry(originalPath: "/Users/x/Downloads/openai-recovery-keys.txt",
                              filename: "openai-recovery-keys.txt", outcome: .neverClassified,
                              reason: "contents mention Polizze Nummer"))
        let raw = try String(contentsOf: file, encoding: .utf8)
        for leak in ["openai", "recovery", "Downloads", "Polizze", "neverClassified", "{"] {
            XCTAssertFalse(raw.contains(leak), "\(leak) is readable on disk")
        }
        XCTAssertTrue(raw.hasPrefix(LogCipher.prefix))
        XCTAssertEqual(Journal(file: file, key: .test).entries.first?.filename, "openai-recovery-keys.txt",
                       "and it still reads back")
    }

    /// A journal from before encryption is sealed on first open, every line kept.
    func testAPlainJournalIsMigratedWithoutLosingALine() throws {
        let file = temp()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let lines = try (0..<25).map { i in
            String(decoding: try enc.encode(JournalEntry(originalPath: "/x/\(i).pdf", filename: "\(i).pdf", outcome: .unsorted)), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let j = Journal(file: file, key: .test)
        XCTAssertEqual(j.latest.count, 25)
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(raw.contains("/x/"), "no plain line left behind")
        XCTAssertEqual(raw.split(separator: "\n").count, 25)
        XCTAssertEqual(Journal(file: file, key: .test).latest.count, 25)
    }

    /// Lines sealed under another key would be dropped by a rewrite. Refuse.
    func testMigrationRefusesAFileWithLinesItCannotOpen() throws {
        let file = temp()
        let foreign = try LogCipher.seal(Data("{}".utf8), key: SymmetricKey(size: .bits256))
        try (foreign + "\n{\"plain\":true}\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(LogCipher.migrate(file, key: .test))
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(foreign), "untouched")
    }

    /// Locked means nothing written at all — not "plain text for now".
    func testALockedJournalWritesNothing() {
        let file = temp()
        let j = Journal(file: file, key: nil)
        XCTAssertTrue(j.isLocked)
        j.record(JournalEntry(originalPath: "/x/a.pdf", filename: "a.pdf", outcome: .moved))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testTamperedLinesAreRejected() throws {
        var line = try LogCipher.seal(Data("hello".utf8), key: .test)
        line.removeLast(4); line += "AAA="
        XCTAssertNil(LogCipher.open(Substring(line), key: .test))
    }
}

extension LogCipherTests {
    /// Anything running as the user could append a plain line and have the
    /// next policy change act on it. After migration, plain lines are ignored
    /// on read and never sealed into the record.
    func testInjectedPlainLinesAreIgnoredAndNeverSealed() throws {
        let file = temp()
        let j = Journal(file: file, key: .test)
        j.record(JournalEntry(originalPath: "/x/real.pdf", filename: "real.pdf", outcome: .unsorted))
        let injected = #"{"id":"00000000-0000-0000-0000-000000000001","timestamp":"2026-09-23T10:00:00Z","originalPath":"/x/victim.pdf","filename":"victim.pdf","outcome":"dryRun","routeProbability":0.99,"proposedPath":"/tmp/elsewhere/victim.pdf"}"#
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data((injected + "\n").utf8)); try handle.close()

        XCTAssertFalse(LogCipher.migrate(file, key: .test), "a mixed file is not migrated")
        let reopened = Journal(file: file, key: .test)
        XCTAssertNil(reopened.latest["/x/victim.pdf"], "the injected line is not believed")
        XCTAssertNotNil(reopened.latest["/x/real.pdf"])
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(injected), "and not sealed into the record")
    }

    /// A crash mid-write leaves a line without its newline. The next append
    /// must start on a fresh line, or both become unreadable.
    func testAnAppendAfterATornWriteStartsOnItsOwnLine() throws {
        let file = temp()
        let j = Journal(file: file, key: .test)
        j.record(JournalEntry(originalPath: "/x/a.pdf", filename: "a.pdf", outcome: .unsorted))
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data("u1:torn-line-without-newline".utf8)); try handle.close()
        j.record(JournalEntry(originalPath: "/x/b.pdf", filename: "b.pdf", outcome: .unsorted))

        let reopened = Journal(file: file, key: .test)
        XCTAssertNotNil(reopened.latest["/x/a.pdf"])
        XCTAssertNotNil(reopened.latest["/x/b.pdf"], "the line after the tear survives")
    }

    func testANewJournalFileIsOwnerOnlyFromTheStart() throws {
        let file = temp()
        Journal(file: file, key: .test).record(JournalEntry(originalPath: "/x/a.pdf", filename: "a.pdf", outcome: .unsorted))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}

@MainActor
final class FileIdentityTests: XCTestCase {
    /// A new "invoice.pdf" downloaded where an old one was already filed used
    /// to look decided, and sat in Downloads forever.
    func testANewFileAtAnOldPathIsDecidedAgain() {
        let j = Journal(file: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-id-\(UUID()).ndjson"), key: .test)
        var e = JournalEntry(originalPath: "/x/invoice.pdf", filename: "invoice.pdf", outcome: .moved)
        e.fileIdentity = "1000-2048"
        j.record(e)
        XCTAssertFalse(j.needsDecision("/x/invoice.pdf", fingerprint: "any", identity: "1000-2048"))
        XCTAssertTrue(j.needsDecision("/x/invoice.pdf", fingerprint: "any", identity: "5000-4096"))
    }
}

final class MoverFolderTests: XCTestCase {
    /// Creating a folder is a decision. Apply used to create whatever was
    /// missing — a renamed route folder, an unmounted drive's whole tree.
    func testApplyRefusesToCreateAFolderUnlessAskedTo() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-mv-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("a.pdf"); try Data("x".utf8).write(to: file)
        let plan = Mover.Plan(source: file, destination: base.appendingPathComponent("missing/a.pdf"))
        XCTAssertThrowsError(try Mover.apply(plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "nothing moved")
        XCTAssertNoThrow(try Mover.apply(plan, createFolders: true))
    }
}
