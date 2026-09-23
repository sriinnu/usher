import XCTest
@testable import Usher

/// `stripped` runs unattended over whole libraries, so its contract is strict:
/// the result must be a subsequence of the input. It may only remove.
final class BookNameTests: XCTestCase {

    private func assertLossless(_ input: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let out = BookName.stripped(for: input) else { return }
        let a = input.lowercased().filter(\.isLetter)
        let b = out.lowercased().filter(\.isLetter)
        var it = a.makeIterator()
        var cursor = it.next()
        for ch in b {
            while cursor != nil, cursor != ch { cursor = it.next() }
            XCTAssertNotNil(cursor, "\(input) -> \(out) invented or reordered characters",
                            file: file, line: line)
            cursor = it.next()
        }
    }

    /// Regression: "epdf" was in the marker list and matched inside "Usagepdf",
    /// turning the title into "…and Usag".
    func testDoesNotEatLettersInsideWords() {
        let out = BookName.stripped(for: "18Hammers German Grammar and Usagepdf - PDF Room.pdf")
        XCTAssertEqual(out, "18Hammers German Grammar and Usagepdf.pdf")
    }

    func testStripsMirrorMarkers() {
        XCTAssertEqual(
            BookName.stripped(for: "German Grammar Simplified (Coles Notes) (na) (z-library.sk, 1lib.sk, z-lib.sk).pdf"),
            "German Grammar Simplified (Coles Notes) (na).pdf")
        XCTAssertEqual(
            BookName.stripped(for: "501 German Verbs (Henry Strutz) (Z-Library).pdf"),
            "501 German Verbs (Henry Strutz).pdf")
    }

    /// Regression: the longest-segment heuristic dropped "A1_A2 level", which is
    /// the single most useful thing in a language-course filename.
    func testKeepsLevelPrefix() {
        let out = BookName.stripped(for:
            "A1_A2 level - German Vocabulary with example sentences (Hermes Language Reference) (Z-Library).epub")
        XCTAssertEqual(out?.hasPrefix("A1_A2 level"), true)
    }

    func testStripsIsbnAndContentHash() {
        let out = BookName.stripped(for:
            "German Grammar Drills -- Edward Swick -- 2018 -- McGraw-Hill -- isbn13 9781260116250 -- 6fcadb1ea379cec1ac931ffeafe8dc77.pdf")
        XCTAssertEqual(out?.contains("9781260116250"), false)
        XCTAssertEqual(out?.contains("6fcadb1e"), false)
        XCTAssertEqual(out?.contains("German Grammar Drills"), true)
    }

    func testLeavesCleanNamesAlone() {
        XCTAssertNil(BookName.stripped(for: "Schritte plus neu 1 A1.1.pdf"))
    }

    func testAlwaysLossless() {
        for name in [
            "Deutsch intensiv - Wortschatz B1 - Das Training. (Arwen Schnack) (Z-Library).pdf",
            "Deutsche Grammatik - einfach, kompakt und übersichtlich - PDF Room.pdf",
            "German verbs -- Silvia Robertson; series editor, Paul Coggle.pdf",
            "Deutsch nach Themen -- Erwin P_ Tschirner -- 2016 -- Cornelsen -- 9783589015597 -- 7ca26c898c04bc69cfcb34daabeaa99b -- Anna's Archive.pdf",
            "1000 Orte mit Präpositionen (unbekannt) (Z-Library).pdf"
        ] {
            assertLossless(name)
        }
    }
}

extension BookNameTests {
    /// Six files survived a full pass: curly apostrophe in "Anna’s Archive",
    /// a bare ISBN-13 with no "isbn" label, and " -  - " debris in between.
    func testCurlyApostropheBareIsbnAndDebris() {
        let name = "German verbs & essentials of grammar - James, Charles J - 2008 - New York_ McGraw-Hill - 9780071498036 -  - Anna’s Archive.pdf"
        let out = BookName.stripped(for: name)
        XCTAssertNotNil(out)
        XCTAssertFalse(out!.localizedCaseInsensitiveContains("anna"), out!)
        XCTAssertFalse(out!.contains("9780071498036"), out!)
        XCTAssertFalse(out!.contains(" -  - "), out!)
        XCTAssertFalse(out!.hasSuffix("- .pdf") || out!.hasSuffix("-.pdf"), out!)
        XCTAssertTrue(out!.hasPrefix("German verbs & essentials of grammar"), out!)
        assertLossless(name)
    }

    func testTenDigitNumbersAreNotMistakenForIsbns() {
        // A phone number or an order id is not an ISBN; only 978/979+10 digits is.
        XCTAssertNil(BookName.stripped(for: "Order 4711234567.pdf"))
        XCTAssertNil(BookName.stripped(for: "Call 5550100123.pdf"))
    }
}
