import Foundation

/// Deterministic routing that runs before the model and never calls the API.
///
/// This exists because "don't send this to a third party" and "don't file this"
/// are different requirements that were tangled together. A bank statement or an
/// insurance policy must not leave the machine — but it still needs to land in the
/// right folder. When the filename or the locally-extracted text is unambiguous,
/// no judgment is needed: code files it and Jev never sees it.
struct LocalRule: Codable, Identifiable {
    var name: String
    var enabled: Bool = true
    /// Case-insensitive regex against the filename. Use `\b` — a bare `lic`
    /// matches "application" and "policy".
    var filenamePattern: String?
    /// Case-insensitive regex against text extracted on-device (PDF text, OCR).
    var contentPattern: String?
    /// Case-insensitive regex against the download's source host.
    var hostPattern: String?
    var destination: String
    var template: String?

    var id: String { name }

    func destinationURL(root: URL) -> URL { DestinationRoot.resolve(destination, root: root) }
}

struct RuleMatch {
    var rule: LocalRule
    /// Which signal fired, for the journal.
    var matchedOn: String
}

enum LocalRules {

    static func load() -> [LocalRule] { loadResult().rules }

    /// The error travels with the rules; a static flag was reset by every
    /// background reload and the view never saw it change.
    static func loadResult() -> (rules: [LocalRule], error: String?) {
        if !FileManager.default.fileExists(atPath: Paths.rules.path) {
            try? Data(defaultRulesJSON.utf8).write(to: Paths.rules, options: .atomic)
        }
        guard let data = try? Data(contentsOf: Paths.rules) else {
            return ([], "rules.json could not be read.")
        }
        do { return (try JSONDecoder().decode([LocalRule].self, from: data).filter(\.enabled), nil) }
        catch { return ([], "rules.json is not valid: \(RouteTable.describe(error))") }
    }

    /// First matching rule wins, so order in rules.json is precedence.
    static func match(_ evidence: Evidence, rules: [LocalRule]) -> RuleMatch? {
        for rule in rules {
            // Tried against the raw name and against the name with its hidden
            // seams opened. Raw keeps patterns like `INV-TG` or `\.p8$` working;
            // opened lets `\bjane\b` see the boundary inside JaneDoePassport,
            // which it otherwise cannot — the rule was silently skipped and the
            // file fell through to be held instead of filed with her.
            if let pattern = rule.filenamePattern,
               matches(pattern, evidence.filename)
                || matches(pattern, SensitiveFilter.opened(evidence.filename)) {
                return RuleMatch(rule: rule, matchedOn: "filename")
            }
            if let pattern = rule.hostPattern,
               let host = evidence.sourceHost,
               matches(pattern, host) {
                return RuleMatch(rule: rule, matchedOn: "source host")
            }
            if let pattern = rule.contentPattern {
                let haystack = [evidence.textExcerpt, evidence.ocrText, evidence.pdfTitle]
                    .compactMap { $0 }.joined(separator: "\n")
                if !haystack.isEmpty, matches(pattern, haystack) {
                    return RuleMatch(rule: rule, matchedOn: "file contents")
                }
            }
        }
        return nil
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Seeded on first run, then edited in
/// `~/Library/Application Support/Usher/rules.json`.
///
/// The rule below is an example of the shape, not a suggestion: replace the
/// pattern and destination with your own. Note `\\b` around short words —
/// a bare `lic` matches "application", and a bare `chit` matches "architect".
///
/// Every rule here bypasses the API entirely — matched files are filed by code and
/// their contents are never transmitted.
let defaultRulesJSON = """
[
  {
    "name": "LIC",
    "enabled": true,
    "filenamePattern": "\\\\blic\\\\b|licindia|\\\\bjeevan\\\\b",
    "contentPattern": "life insurance corporation|lic of india",
    "destination": "{root}/Documents/Insurance",
    "template": "{name}.{ext}"
  }
]
"""
