import XCTest
@testable import Usher

/// These guard a bug that shipped: the filter matched patterns as plain
/// substrings, so "lic" fired on `hdfc-filled-application.pdf`, "chit" fired on
/// `ARCHITECTURE.md` and `Chitragupta`, and "emi" would fire on anything academic.
/// Every one of those is held as a private financial record and never filed.
final class SensitiveFilterTests: XCTestCase {

    private func settings(patterns: [String], hosts: [String] = []) -> AppSettings {
        var s = AppSettings.default
        s.sensitivePatterns = patterns
        s.sensitiveHosts = hosts
        s.sensitiveImageLabels = []
        return s
    }

    private func evidence(_ filename: String,
                          host: String? = nil,
                          labels: [ImageLabel]? = nil) -> Evidence {
        Evidence(filename: filename,
                 ext: (filename as NSString).pathExtension,
                 sizeBytes: 1024,
                 sourceHost: host,
                 imageLabels: labels)
    }

    func testShortPatternsDoNotMatchInsideLongerWords() {
        let s = settings(patterns: ["lic", "chit", "emi", "tax", "axis"])
        let mustNotMatch = [
            "hdfc-filled-application.pdf",      // app-LIC-ation
            "ARCHITECTURE.md",                  // ar-CHIT-ecture
            "for-takumi-chitragupta-binding.md",// CHIT-ragupta
            "01_Architect_Ledger_CV.pdf",
            "academic-paper.pdf",               // acad-EMI-c
            "chemistry-notes.pdf",              // ch-EMI-stry
            "taxonomy-of-types.pdf",            // TAX-onomy
            "praxis-guide.pdf"                  // pr-AXIS
        ]
        for name in mustNotMatch {
            XCTAssertFalse(SensitiveFilter.check(evidence(name), settings: s).isSensitive,
                           "\(name) must not be held")
        }
    }

    func testShortPatternsStillMatchTheRealThing() {
        let s = settings(patterns: ["lic", "chit", "emi", "tax", "bank"])
        // "Chits" and "banks" must match the singular pattern — a whole-word rule
        // that ignores plurals is a trap for anyone writing their own.
        let mustMatch = ["LIC .png", "Chits-june.png", "EMI-statement.pdf",
                         "tax-2025.pdf", "taxes-2025.pdf", "banks-overview.pdf"]
        for name in mustMatch {
            XCTAssertTrue(SensitiveFilter.check(evidence(name), settings: s).isSensitive,
                          "\(name) must be held")
        }
    }

    /// Hosts are matched as substrings on purpose — a word boundary would miss
    /// netbanking.hdfcbank.com.
    func testHostsMatchAsSubstrings() {
        let s = settings(patterns: [], hosts: ["hdfc"])
        XCTAssertTrue(SensitiveFilter.check(
            evidence("statement.pdf", host: "netbanking.hdfcbank.com"), settings: s).isSensitive)
    }

    /// A phone photo of a passport has no useful filename and no source URL, so
    /// only the on-device Vision label can catch it before anything is sent.
    func testImageLabelHoldsAnIdentityDocument() {
        var s = settings(patterns: [])
        s.sensitiveImageLabels = ["passport"]
        s.sensitiveLabelThreshold = 0.30
        let verdict = SensitiveFilter.check(
            evidence("IMG_2451.jpg", labels: [ImageLabel(label: "passport", confidence: 0.54)]),
            settings: s)
        XCTAssertTrue(verdict.isSensitive)
    }

    func testImageLabelBelowThresholdIsIgnored() {
        var s = settings(patterns: [])
        s.sensitiveImageLabels = ["passport"]
        s.sensitiveLabelThreshold = 0.60
        XCTAssertFalse(SensitiveFilter.check(
            evidence("IMG_2451.jpg", labels: [ImageLabel(label: "passport", confidence: 0.40)]),
            settings: s).isSensitive)
    }
}

extension SensitiveFilterTests {

    /// A sweep held 95 files; 72 were caught only by the model, after they had
    /// already been sent. Most were scans named with words run together.
    func testCamelCaseSeamsCountAsWordBoundaries() {
        var s = AppSettings.default
        s.sensitivePatterns = ["passport", "lic"]
        s.sensitiveImageLabels = []
        func ev(_ n: String) -> Evidence { Evidence(filename: n, ext: "pdf", sizeBytes: 1) }

        XCTAssertTrue(SensitiveFilter.check(ev("JaneDoePassport.pdf"), settings: s).isSensitive,
                      "Doe|Passport is a word seam")
        XCTAssertTrue(SensitiveFilter.check(ev("Passport Scan.pdf"), settings: s).isSensitive)
        // The seam rule must not reopen the substring bug.
        XCTAssertFalse(SensitiveFilter.check(ev("hdfc-filled-application.pdf"), settings: s).isSensitive,
                       "no seam inside `application`, so `lic` still cannot match")
        XCTAssertFalse(SensitiveFilter.check(ev("PublicNotice.pdf"), settings: s).isSensitive,
                       "Pub|lic: `lic` follows a seam but is not a whole word — `licNotice`")
    }
}

extension SensitiveFilterTests {

    /// 76 of 101 held files had names no pattern could ever match — bare codes
    /// like `DOC-0001 (12).pdf`. Only the text on the page identifies them, and that
    /// text is already extracted locally before any send.
    func testExtractedTextIsCheckedBeforeSending() {
        let s = AppSettings.default
        var e = Evidence(filename: "DOC-0001 (12).pdf", ext: "pdf", sizeBytes: 1)
        e.textExcerpt = "Kontoauszug Nr. 12\nIBAN DE89 3704 0044 0532 0130 00\nAlter Saldo"
        XCTAssertTrue(SensitiveFilter.check(e, settings: s).isSensitive)

        var r = Evidence(filename: "0000-TEST-0000.pdf", ext: "pdf", sizeBytes: 1)
        r.textExcerpt = "Aufenthaltstitel — Residence permit\nName\nDate of birth 12.03.1990"
        XCTAssertTrue(SensitiveFilter.check(r, settings: s).isSensitive)
    }

    /// The content list must be stricter than the filename list, or every German
    /// exercise book trips on "Bank" and "Termin".
    func testTextbookProseDoesNotTripTheContentCheck() {
        let s = AppSettings.default
        var e = Evidence(filename: "Schritte plus neu 2 A1.2.pdf", ext: "pdf", sizeBytes: 1)
        e.textExcerpt = """
        Lektion 5: Auf der Bank. Ich habe einen Termin um 10 Uhr. Wie viel kostet das?
        Ergänzen Sie: Ich gehe zur Bank und hebe Geld ab. Der Preis ist gut.
        Steuern: Mehrwertsteuer ist 19 Prozent. Wo ist die Versicherung?
        """
        XCTAssertFalse(SensitiveFilter.check(e, settings: s).isSensitive,
                       "common nouns in a lesson are not a personal record")
    }
}

extension SensitiveFilterTests {

    /// Each of these was a real file the filter missed while the model caught it
    /// — which is to say, after it had been sent.
    func testSeamsFilenamesHide() {
        var s = AppSettings.default
        s.sensitivePatterns = ["rechnung", "residence permit", "w2", "steuer-id", "lic"]
        s.sensitiveImageLabels = []
        func held(_ n: String) -> Bool {
            SensitiveFilter.check(Evidence(filename: n, ext: (n as NSString).pathExtension, sizeBytes: 1),
                                  settings: s).isSensitive
        }
        XCTAssertTrue(held("rechnung01012026_1.jpeg"),   "letter→digit seam")
        XCTAssertTrue(held("PPT-Residence_permit.pdf"),  "underscore stands for a space")
        XCTAssertTrue(held("W2_2025.pdf"),               "pattern with a digit still matches")
        XCTAssertTrue(held("Steuer-ID Bescheinigung.pdf"), "hyphenated pattern matches hyphenated name")
        XCTAssertFalse(held("hdfc-filled-application.pdf"), "still no seam inside `application`")
        XCTAssertFalse(held("public-notice.pdf"),        "`lic` inside `public` has no seam")
    }

    func testHTMLIsReadAsTextForTheContentCheck() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-html-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("INV-2026.html")
        try """
        <html><head><style>body{font:1em}</style><script>var x=1;</script></head>
        <body><h1>Tax Invoice</h1><p>Invoice number: 4711</p><p>Amount due: &euro;120</p></body></html>
        """.write(to: url, atomically: true, encoding: .utf8)
        let e = EvidenceExtractor.extract(from: url)
        let text = try XCTUnwrap(e.textExcerpt)
        XCTAssertFalse(text.contains("<"), "markup stripped: \(text)")
        XCTAssertFalse(text.contains("var x"), "script stripped")
        XCTAssertTrue(SensitiveFilter.check(e, settings: .default).isSensitive)
    }
}

extension SensitiveFilterTests {

    /// A certified copy of a passport page, OCR'd. No word list names an MRZ.
    func testPassportMachineReadableZoneIsHeld() {
        var e = Evidence(filename: "PPT-scan.pdf", ext: "pdf", sizeBytes: 1)
        e.ocrText = "REPUBLIC OF INDIA\nP<INDPENDELA<<SRINIVAS<RAO<<<<<<<<<<<<<<<<<<\n74599388<5IND"
        var s = AppSettings.default
        s.sensitiveContentPatterns = []          // the MRZ check alone must carry it
        XCTAssertTrue(SensitiveFilter.check(e, settings: s).isSensitive)
    }

    /// A bank export named file.csv: nothing in the name, everything in the header row.
    func testTransactionExportIsHeldByItsHeader() {
        var e = Evidence(filename: "file.csv", ext: "csv", sizeBytes: 1)
        e.textExcerpt = "Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\nDeposit,Current,2020-05-30,2020-05-30,Top-up by *1234,30.00,0.00,EUR,COMPLETED,30.00"
        XCTAssertTrue(SensitiveFilter.check(e, settings: .default).isSensitive)
    }

    /// The user's own identifiers make a page theirs — but the list is empty in
    /// source, so a paper carrying a stranger's email is not held by this rule.
    func testPersonalIdentifiersAreUserSuppliedOnly() {
        var e = Evidence(filename: "INV-2026.html", ext: "html", sizeBytes: 1)
        e.textExcerpt = "Acme Fibre Registered Mobile 5550100123 Email someone@example.com"
        var s = AppSettings.default
        s.sensitiveContentPatterns = []
        XCTAssertFalse(SensitiveFilter.check(e, settings: s).isSensitive, "no identifiers configured")
        s.personalIdentifiers = ["someone@example.com"]
        XCTAssertTrue(SensitiveFilter.check(e, settings: s).isSensitive)
        XCTAssertTrue(AppSettings.default.personalIdentifiers.isEmpty, "never seeded in source")
    }
}
