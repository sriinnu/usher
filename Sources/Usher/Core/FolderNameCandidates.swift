import Foundation

/// When no existing folder fits, something has to propose a name for a new one.
/// Jev does not generate text, so code produces the candidates and the model picks
/// — and even then the folder is only ever created after you approve it.
enum FolderNameCandidates {

    /// Tokens that appear in downloaded filenames and never belong in a folder name.
    private static let noise: Set<String> = [
        "hd", "4k", "8k", "uhd", "full", "fullhd", "wallpaper", "wallpapers",
        "photo", "photos", "pic", "pics", "picture", "pictures", "image", "images",
        "download", "downloads", "free", "stock", "getty", "shutterstock", "alamy",
        "hq", "high", "resolution", "res", "quality", "original", "final", "copy",
        "new", "latest", "best", "top", "thumb", "thumbnail", "preview", "sample",
        "scaled", "cropped", "edited", "final2", "v1", "v2", "img", "dsc", "screenshot",
        "untitled", "unnamed", "default", "output", "export", "file", "document",
        "attachment", "attachments", "scan", "scanned", "whatsapp", "telegram",
        "signal", "unknown", "temp", "tmp", "new"
    ]

    static func build(for evidence: Evidence, limit: Int = 8) -> [String] {
        var candidates: [String] = []

        func add(_ raw: String?) {
            guard let cleaned = normalize(raw) else { return }
            guard !candidates.contains(cleaned) else { return }
            candidates.append(cleaned)
        }

        /// A filename like `alia-bhatt-red-carpet-met-gala` carries the subject in
        /// its first two words and the occasion in the rest. Code cannot tell where
        /// one ends, so it offers each prefix and lets the model choose.
        func addPrefixes(of words: [String]?) {
            guard let words, !words.isEmpty else { return }
            for length in 2...max(2, min(words.count, 4)) where length <= words.count {
                add(words.prefix(length).joined(separator: " "))
            }
            if words.count == 1 { add(words[0]) }
        }

        addPrefixes(of: words(fromFilename: evidence.filename))
        addPrefixes(of: words(fromURL: evidence.referrerURL))
        addPrefixes(of: words(fromURL: evidence.sourceURL))
        add(evidence.pdfTitle)
        add(firstProperNounLine(evidence.ocrText))

        return Array(candidates.prefix(limit))
    }

    // MARK: - Sources

    private static func words(fromFilename filename: String) -> [String]? {
        meaningfulWords(from: (filename as NSString).deletingPathExtension)
    }

    /// The slug in a URL is usually the cleanest subject name available:
    /// `/entertainment/south/samantha-ruth-prabhu-photos` beats the filename.
    private static func words(fromURL raw: String?) -> [String]? {
        guard let raw, let url = URL(string: raw) else { return nil }
        let segments = url.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
            .map { ($0 as NSString).deletingPathExtension }

        // Longest segment that still reads like words rather than an id.
        return segments
            .compactMap { meaningfulWords(from: $0) }
            .max { $0.count < $1.count }
    }

    /// A line of OCR that looks like a name: two or three capitalised words.
    private static func firstProperNounLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(separator: "\n").prefix(15) {
            let words = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ")
                .map(String.init)
            guard (2...3).contains(words.count) else { continue }
            let allCapitalised = words.allSatisfy { word in
                guard let first = word.first else { return false }
                return first.isUppercase && word.dropFirst().allSatisfy { $0.isLowercase }
            }
            guard allCapitalised else { continue }
            return words.joined(separator: " ")
        }
        return nil
    }

    // MARK: - Cleaning

    /// Splits on the separators downloads use, drops noise and bare numbers, and
    /// title-cases what is left.
    private static func meaningfulWords(from raw: String) -> [String]? {
        // Not "%20": a CharacterSet is a set of characters, so that string made
        // every 2 and 0 a word break — "98d1d0f5" came out as "98d1d" and "F5",
        // and a folder called "98d1d F5" was proposed. The literal "%20" is
        // already replaced with a space on the line above.
        let separators = CharacterSet(charactersIn: "-_.+ ")
        let words = raw
            .replacingOccurrences(of: "%20", with: " ")
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { word in
                guard word.count >= 2 else { return false }
                guard !noise.contains(word.lowercased()) else { return false }
                // Drop pure numbers, dimensions, and hex-looking ids.
                guard word.contains(where: { $0.isLetter }) else { return false }
                if word.range(of: "^[0-9]+x[0-9]+$", options: .regularExpression) != nil { return false }
                // Hex chunks of any useful length, and the letter-digit mash of a
                // random id ("Snsd91g", "m1j1lsntkAv1n5xvh7mp"): not names.
                // All-hex with at least one digit is an id at any length: "41a5",
                // "9ef1". Real words that happen to be hex letters ("cafe",
                // "bead") have no digit and survive.
                if word.count >= 3, word.contains(where: \.isNumber),
                   word.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil { return false }
                if word.count <= 2, word.contains(where: \.isNumber) { return false }
                let digits = word.filter(\.isNumber).count
                if word.count >= 6, digits * 100 / word.count >= 25 { return false }
                if word.count >= 10, word.range(of: "[0-9]", options: .regularExpression) != nil,
                   word.range(of: "[aeiouAEIOU]{1}", options: .regularExpression) == nil { return false }
                return true
            }
            .prefix(5)

        guard !words.isEmpty else { return nil }
        return words.map(titleCase)
    }

    private static func titleCase(_ word: String) -> String {
        // Leave names that are already cased sensibly alone (McCartney, iPhone).
        if word.dropFirst().contains(where: { $0.isUppercase }) { return word }
        return word.prefix(1).uppercased() + word.dropFirst().lowercased()
    }

    private static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard cleaned.count >= 3, cleaned.count <= 60 else { return nil }
        return cleaned
    }
}
