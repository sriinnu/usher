import XCTest
@testable import Usher

/// Word, Excel and legacy .doc files classified on their name alone, so
/// "document (3).docx" had no chance and a bank letter saved as .docx was
/// never seen by the privacy filter. Fixtures are made with macOS's own
/// textutil, so they are real Office files, not hand-rolled approximations.
final class OfficeReadTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-office-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func convert(_ text: String, to format: String) throws -> URL {
        let src = dir.appendingPathComponent("in.txt")
        try text.write(to: src, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        p.arguments = ["-convert", format, src.path, "-output", dir.appendingPathComponent("out.\(format)").path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return dir.appendingPathComponent("out.\(format)")
    }

    func testDocxIsReadAndFilterSeesIt() throws {
        let url = try convert("Kontoauszug Nr. 4\nIBAN DE89 3704 0044 0532 0130 00\nAlter Saldo 12,00", to: "docx")
        let e = EvidenceExtractor.extract(from: url)
        let text = try XCTUnwrap(e.textExcerpt)
        XCTAssertTrue(text.contains("Kontoauszug"), text)
        XCTAssertFalse(text.contains("<w:"), "XML stripped: \(text)")
        XCTAssertTrue(SensitiveFilter.check(e, settings: .default).isSensitive, "held before any send")
    }

    func testLegacyDocIsRead() throws {
        let url = try convert("Schritte plus Neu 3 — Lektion 5 Arbeitsblatt", to: "doc")
        let e = EvidenceExtractor.extract(from: url)
        XCTAssertTrue(e.textExcerpt?.contains("Lektion 5") == true, e.textExcerpt ?? "nil")
    }

    func testRtfIsReadAsTextNotMarkup() throws {
        let url = try convert("Plain words only", to: "rtf")
        let e = EvidenceExtractor.extract(from: url)
        XCTAssertEqual(e.textExcerpt, "Plain words only")
    }
}
