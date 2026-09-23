import XCTest
@testable import Usher

final class LocalRulesTests: XCTestCase {

    private func ev(_ name: String) -> Evidence {
        Evidence(filename: name, ext: (name as NSString).pathExtension, sizeBytes: 1)
    }

    /// `JaneDoePassport.pdf` fell past a `\bjane\b` rule and was held instead
    /// of filed with her. A rule must see the seams a filename hides, the same
    /// way the privacy filter does.
    func testWordBoundedRuleSeesCamelCaseSeams() {
        let rule = LocalRule(name: "Family", filenamePattern: #"\bjane\b|\bdoe\b"#, destination: "/x")
        XCTAssertNotNil(LocalRules.match(ev("JaneDoePassport.pdf"), rules: [rule]))
        XCTAssertNotNil(LocalRules.match(ev("Jane Doe Ppt.jpg"), rules: [rule]))
        XCTAssertNil(LocalRules.match(ev("Janeiro-trip.jpg"), rules: [rule]), "still whole-word")
    }

    /// Opening seams must not break patterns written against the raw name.
    func testRawPatternsStillMatchTheRawName() {
        let inv = LocalRule(name: "Inv", filenamePattern: "^INV-TG-", destination: "/x")
        XCTAssertNotNil(LocalRules.match(ev("INV-TG-B1-159430250.html"), rules: [inv]))
        let ext = LocalRule(name: "Ext", filenamePattern: #"\.kdbx$"#, destination: "/x")
        XCTAssertNotNil(LocalRules.match(ev("vault.kdbx"), rules: [ext]))
    }

    func testFirstMatchingRuleWins() {
        let a = LocalRule(name: "A", filenamePattern: "report", destination: "/a")
        let b = LocalRule(name: "B", filenamePattern: "report", destination: "/b")
        XCTAssertEqual(LocalRules.match(ev("report.pdf"), rules: [a, b])?.rule.name, "A")
    }
}
