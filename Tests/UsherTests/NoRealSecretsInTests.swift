import XCTest
@testable import Usher

/// Test fixtures are synthetic. A secret-shaped literal in a test file is
/// indistinguishable from a leak — to a reader, to GitHub's secret scanning,
/// and to the next person who pastes a real key "just to test". The first
/// public commit had to be cut from a history whose fixtures held a real
/// Apple key ID, a real phone number and a real IBAN.
///
/// So every fake secret is built at runtime in `Fixtures.swift` from obvious
/// TEST parts, and this test runs Usher's own detectors over every test file:
/// no line of test source may look like a secret.
final class NoRealSecretsInTests: XCTestCase {
    func testNoTestFileContainsASecretShapedLiteral() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if let kind = SecretContent.detect(text: String(line)) {
                    offenders.append("\(file.lastPathComponent):\(n + 1) — \(kind)")
                }
            }
            // Real Apple key IDs are ten characters; fixtures use the obvious one.
            let keyID = try NSRegularExpression(pattern: "AuthKey_[A-Z0-9]{10}")
            for m in keyID.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range, in: text), text[r] != "AuthKey_ABCDE12345" else { continue }
                offenders.append("\(file.lastPathComponent) — an Apple key ID that is not the fixture one")
            }
        }
        XCTAssertTrue(offenders.isEmpty, "secret-shaped literals in tests:\n" + offenders.joined(separator: "\n"))
    }

    /// Personal data has shapes too. Fixtures use the values reserved for
    /// examples — example.com, the 555-01xx range, the textbook IBANs — so a
    /// real one stands out as a failure instead of passing as "test data".
    func testFixturesUseReservedExampleValuesOnly() throws {
        var offenders: [String] = []
        let email = try NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
        let phone = try NSRegularExpression(pattern: #"(?i)(mobile|phone|tel|call|whatsapp|\+)[^0-9\n]{0,24}(\d[\d -]{7,}\d)"#)
        let iban  = try NSRegularExpression(pattern: #"\b[A-Z]{2}\d{2}(?: ?[0-9A-Z]{4}){3,7}(?: ?[0-9A-Z]{1,3})?\b"#)
        let textbookIBANs: Set<String> = ["DE89370400440532013000", "GB82WEST12345698765432"]

        for (file, text) in try testSources() {
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line), where_ = "\(file):\(n + 1)"
                for m in email.matches(in: l, range: NSRange(l.startIndex..., in: l)) {
                    let value = String(l[Range(m.range, in: l)!]).lowercased()
                    if !value.hasSuffix("@example.com"), !value.hasSuffix(".example.com") {
                        offenders.append("\(where_) — an email that is not @example.com")
                    }
                }
                for m in phone.matches(in: l, range: NSRange(l.startIndex..., in: l)) {
                    let digits = String(l[Range(m.range(at: 2), in: l)!]).filter(\.isNumber)
                    if !(digits.hasPrefix("55501") || digits.hasPrefix("155501")) {
                        offenders.append("\(where_) — a phone number outside the fictional 555-01xx range")
                    }
                }
                for m in iban.matches(in: l, range: NSRange(l.startIndex..., in: l)) {
                    let value = String(l[Range(m.range, in: l)!]).replacingOccurrences(of: " ", with: "")
                    guard value.count >= 15, value.dropFirst(2).prefix(2).allSatisfy(\.isNumber),
                          value.contains(where: \.isNumber) else { continue }
                    if !textbookIBANs.contains(value) { offenders.append("\(where_) — an IBAN that is not a textbook example") }
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "personal-data-shaped fixtures:\n" + offenders.joined(separator: "\n"))
    }

    /// Names, places and folder names cannot be listed in a public repository —
    /// the list would publish them. So the list lives outside it, in
    /// ~/.config/usher/private-terms.txt (one term per line, owner-only), and
    /// a failure names the file and line, never the term.
    func testNoPrivateTermAppearsInATest() throws {
        let list = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/usher/private-terms.txt")
        guard let raw = try? String(contentsOf: list, encoding: .utf8) else {
            throw XCTSkip("no private-terms list on this machine")
        }
        let terms = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.count >= 3 && !$0.hasPrefix("#") }
        var offenders: [String] = []
        for (file, text) in try testSources() {
            for (n, line) in text.lowercased().split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where terms.contains(where: { line.contains($0) }) {
                offenders.append("\(file):\(n + 1)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, "a private term appears in: " + offenders.joined(separator: ", "))
    }

    private func testSources() throws -> [(String, String)] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }
}
