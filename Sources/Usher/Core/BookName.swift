import Foundation

/// Book filenames from libgen, z-library and friends carry the whole catalogue
/// record in the name: edition, author, year, publisher, ISBN, and a content hash.
/// Jev cannot write a better name, so code pulls the record apart and offers the
/// sensible spellings as candidates for it to choose between.
///
///   `German Grammar Drills, Third Edition -- Edward Swick -- 3, 2018 --
///    McGraw-Hill Education; McGraw Hill -- isbn13 9781260116250 -- 6fcadb1e….pdf`
///   becomes `German Grammar Drills`, `German Grammar Drills - Edward Swick`,
///   `German Grammar Drills - Edward Swick (2018)`.
enum BookName {

    /// Mirror markers that can be stripped wherever they appear: domain forms
    /// and multi-word names that occur in no real title.
    private static let sourceMarkers = [
        "libgen.li", "libgen.rs", "libgen.is", "z-library.sk", "z-lib.sk", "1lib.sk",
        "z-library", "zlibrary", "annas-archive", "annas-archive.org", "annas archive",
        "anna's archive", "anna\u{2019}s archive", "anna\u{2018}s archive",
        "vdoc.pub", "dokumen.pub", "pdfdrive", "bookfi", "pdf room", "pdfroom"
    ]

    /// Names that are also real software: stripped only in the shapes a mirror
    /// uses — inside parentheses, or as a trailing " - X" segment — never bare.
    /// Bare stripping turned zlib-1.3.1.tar.gz into 1.3.1.tar.gz and
    /// libgen-tools.zip into tools.zip on the way into the Software folder.
    private static let contextualMarkers = ["libgen", "zlib", "b-ok", "epdf", "openlibrary"]

    private static let publisherMarkers = [
        "press", "publishing", "publisher", "publications", "education", "media",
        "books", "verlag", "hueber", "klett", "cornelsen", "langenscheidt",
        "o'reilly", "oreilly", "packt", "springer", "wiley", "manning", "apress",
        "mcgraw", "pearson", "routledge", "bharatiya vidya bhavan", "penguin"
    ]

    /// Conservative cleanup: removes mirror markers, ISBNs and content hashes,
    /// then tidies the spacing. Word order is never changed and nothing is
    /// promoted or dropped, so it is safe to run unattended over a whole library.
    ///
    /// The restructuring in `candidates(for:)` guesses which segment is the author
    /// and reorders accordingly — useful when a model picks between options, far
    /// too risky for a bulk rename. "Deutsche Grammatik" reads as a person's name
    /// to that heuristic.
    static func stripped(for filename: String) -> String? {
        let ext = (filename as NSString).pathExtension
        let original = (filename as NSString).deletingPathExtension

        var stem = stripSources(original)
        stem = stripISBN(stem)
        stem = stripHashes(stem)
        stem = tidy(stem)
        // Separator debris left where segments were removed — runs of " - - ",
        // and dangling separators at either end. Loop until nothing changes;
        // one pass leaves "X - 978… -  - Anna’s Archive" as "X - ".
        var previous = ""
        while previous != stem {
            previous = stem
            stem = stem.replacingOccurrences(of: "\\s*[-–—]{2,}\\s*", with: " - ",
                                             options: .regularExpression)
            stem = stem.replacingOccurrences(of: "(\\s*[-–—]\\s*){2,}", with: " - ",
                                             options: .regularExpression)
            stem = stem.replacingOccurrences(of: "\\s*[-–—]\\s*$", with: "",
                                             options: .regularExpression)
            stem = stem.replacingOccurrences(of: "^\\s*[-–—]\\s*", with: "",
                                             options: .regularExpression)
            stem = trimEdges(stem)
        }

        guard !stem.isEmpty, stem.count >= 3, stem != original else { return nil }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// Candidate names, cleanest first. Empty when the name has nothing to strip.
    static func candidates(for filename: String) -> [String] {
        let ext = (filename as NSString).pathExtension
        var stem = (filename as NSString).deletingPathExtension

        let original = stem
        stem = stripSources(stem)
        stem = stripISBN(stem)
        stem = stripHashes(stem)

        // Nothing meaningful was removed, so there is no cleaner spelling to offer.
        guard normalised(stem) != normalised(original) || stem.contains("--") else { return [] }

        let year = extractYear(stem)
        let segments = split(stem)
            .map { trimEdges($0) }
            .filter { !$0.isEmpty && !isNoiseSegment($0) }

        guard !segments.isEmpty else { return [] }

        let (title, author) = titleAndAuthor(segments)
        guard let title, title.count >= 3 else { return [] }

        var names: [String] = []
        func add(_ value: String) {
            let cleaned = tidy(value)
            guard cleaned.count >= 3, cleaned.count <= 110 else { return }
            let withExt = ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
            guard !names.contains(withExt) else { return }
            names.append(withExt)
        }

        if let author, let year {
            add("\(title) - \(author) (\(year))")
        }
        if let author {
            add("\(title) - \(author)")
        }
        if let year {
            add("\(title) (\(year))")
        }
        add(title)

        return names
    }

    // MARK: - Stripping

    private static func stripSources(_ text: String) -> String {
        var result = text
        for marker in contextualMarkers {
            let m = NSRegularExpression.escapedPattern(for: marker)
            result = result.replacingOccurrences(
                of: "\\(([^()]*\\b\(m)\\b[^()]*)\\)", with: "",
                options: [.regularExpression, .caseInsensitive])
            result = result.replacingOccurrences(
                of: "\\s+[-–—]{1,2}\\s*\(m)\\s*$", with: "",
                options: [.regularExpression, .caseInsensitive])
        }
        for marker in sourceMarkers {
            // Both `(z-library.sk, 1lib.sk)` and a trailing ` - libgen.li`.
            result = result.replacingOccurrences(
                of: "\\(([^()]*\(NSRegularExpression.escapedPattern(for: marker))[^()]*)\\)",
                with: "", options: [.regularExpression, .caseInsensitive])
            result = result.replacingOccurrences(
                of: "[-–—]{1,2}\\s*\(NSRegularExpression.escapedPattern(for: marker))\\s*",
                with: " ", options: [.regularExpression, .caseInsensitive])
            // Delimited, never bare: "epdf" occurs inside "Usagepdf", and a bare
            // replacement eats real letters out of the title.
            result = result.replacingOccurrences(
                of: "(?<![A-Za-z])\(NSRegularExpression.escapedPattern(for: marker))(?![A-Za-z])",
                with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    private static func stripISBN(_ text: String) -> String {
        var t = text.replacingOccurrences(
            of: "isbn\\s*(13|10)?\\s*:?\\s*[0-9Xx\\-]{9,20}",
            with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(
            of: "(?<![0-9])97[89][0-9]{10}(?![0-9])",
            with: "", options: .regularExpression)
        return t
    }

    /// Content hashes: long unbroken hex runs, which no title ever contains.
    private static func stripHashes(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\b[0-9a-fA-F]{16,}\\b", with: "", options: .regularExpression)
    }

    // MARK: - Parsing

    private static func split(_ text: String) -> [String] {
        // `--` is the dominant separator in these dumps; fall back to ` - `.
        if text.contains("--") {
            return text.components(separatedBy: "--")
        }
        return text.components(separatedBy: " - ")
    }

    private static func extractYear(_ text: String) -> String? {
        guard let match = text.range(of: "(19|20)\\d{2}", options: .regularExpression) else { return nil }
        return String(text[match])
    }

    /// Segments that are pure metadata rather than title or author.
    private static func isNoiseSegment(_ segment: String) -> Bool {
        let lower = segment.lowercased()
        if publisherMarkers.contains(where: { lower.contains($0) }) { return true }
        // "3, 2018" — an edition/year pair with no words in it.
        if segment.range(of: "^[0-9,\\s.]+$", options: .regularExpression) != nil { return true }
        if lower.range(of: "^(vol|volume|ed|edition|no)\\.?\\s*[0-9]+$",
                       options: .regularExpression) != nil { return true }
        return segment.count < 2
    }

    /// Heuristic: a person's name is short and has few words; a title is longer.
    /// `Author - Title` and `Title -- Author` both occur, so pick by shape.
    private static func titleAndAuthor(_ segments: [String]) -> (String?, String?) {
        guard segments.count > 1 else { return (segments.first, nil) }

        let first = segments[0], second = segments[1]
        if looksLikePersonName(first), !looksLikePersonName(second) {
            return (second, first)   // "Daniela Niebisch - Schritte plus neu 1"
        }
        if looksLikePersonName(second) {
            return (first, second)   // "German Grammar Drills -- Edward Swick"
        }
        // Neither reads as a name. Keep every segment rather than picking the
        // longest: "A1_A2 level - German Vocabulary" would otherwise lose the
        // level, which is the single most useful thing in the name.
        return (segments.joined(separator: " - "), nil)
    }

    private static func looksLikePersonName(_ segment: String) -> Bool {
        let words = segment.split(separator: " ").map(String.init)
        guard (2...4).contains(words.count) else { return false }
        guard segment.count <= 40 else { return false }
        // Mostly capitalised words, no digits.
        guard !segment.contains(where: \.isNumber) else { return false }
        let capitalised = words.filter { $0.first?.isUppercase == true }.count
        return capitalised >= words.count - 1
    }

    // MARK: - Tidying

    private static func trimEdges(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—_.")).trimmingCharacters(in: .whitespaces)
    }

    private static func tidy(_ text: String) -> String {
        var result = text
        // Collapse the gaps left behind by everything we removed.
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\(\\s*\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+([,;)])", with: "$1", options: .regularExpression)
        result = result.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
        return trimEdges(result)
    }

    private static func normalised(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}
