import XCTest
import PDFKit
import AppKit
@testable import Usher

/// A residence permit arrived as a six-page PDF with no text layer. The
/// extractor read it as a PDF containing nothing, and "nothing" is the worst
/// possible evidence: the model classifies it confidently on no information,
/// and the local content check has no text to inspect. Scans must be OCR'd.
final class ScannedPDFTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usher-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Builds a PDF whose only content is a bitmap of rendered text — the shape
    /// every phone scan and flatbed scan has.
    private func imageOnlyPDF(saying text: String) throws -> URL {
        let size = NSSize(width: 1000, height: 400)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(
            at: NSPoint(x: 40, y: 160),
            withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
        image.unlockFocus()

        let doc = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: image))
        doc.insert(page, at: 0)
        let url = dir.appendingPathComponent("scan.pdf")
        XCTAssertTrue(doc.write(to: url))

        // Sanity: the fixture really has no text layer.
        XCTAssertEqual(PDFDocument(url: url)?.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", "")
        return url
    }

    func testScannedPDFIsReadByOCRBeforeAnythingIsSent() throws {
        let url = try imageOnlyPDF(saying: "Aufenthaltstitel Residence Permit")
        let evidence = EvidenceExtractor.extract(from: url)

        XCTAssertNil(evidence.textExcerpt, "no text layer to extract")
        let ocr = try XCTUnwrap(evidence.ocrText, "a scan must be OCR'd, not treated as empty")
        XCTAssertTrue(ocr.localizedCaseInsensitiveContains("Aufenthaltstitel")
                      || ocr.localizedCaseInsensitiveContains("Residence"), ocr)

        // And the local content check sees it, so it is held before any send.
        XCTAssertTrue(SensitiveFilter.check(evidence, settings: .default).isSensitive)
    }
}
