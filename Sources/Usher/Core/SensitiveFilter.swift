import Foundation

/// Runs before anything is sent anywhere. A file that trips this filter is never
/// serialized into a request body; it stays where it is and gets journaled as held.
enum SensitiveFilter {

    struct Verdict {
        var isSensitive: Bool
        var reason: String?
    }

    /// A bare file name against the extension list and your filename patterns.
    /// For names that travel in a request without being the file itself: the
    /// entries of an archive, the samples of a folder, the files already in a
    /// destination folder.
    static func nameIsSensitive(_ name: String, settings: AppSettings) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, settings.sensitiveExtensions.contains(ext) { return true }
        return settings.sensitivePatterns.contains { matchesWord($0, in: name) }
    }

    static func check(_ evidence: Evidence, settings: AppSettings) -> Verdict {
        // Case is preserved here on purpose: matchesWord opens word boundaries at
        // camelCase seams before it lowercases.
        let haystacks = [
            evidence.filename,
            evidence.pdfTitle ?? "",
            evidence.sourceURL ?? ""
        ].joined(separator: " ")

        // Some formats are secrets by definition. A password-manager export is
        // encrypted, so its contents never leave the machine — but its filename
        // names the site and the account, and 2,108 of those were sent before
        // this check existed. Extension first, before anything else is looked at.
        if settings.sensitiveExtensions.contains(evidence.ext.lowercased()) {
            return Verdict(isSensitive: true,
                           reason: ".\(evidence.ext.lowercased()) files are never sent")
        }

        for pattern in settings.sensitivePatterns {
            guard matchesWord(pattern, in: haystacks) else { continue }
            return Verdict(isSensitive: true, reason: "filename or title matched \"\(pattern)\"")
        }

        // Text read locally off the page. This is what catches a document whose
        // name is a bare code — DOC-0001.pdf, 0000-TEST-0000.pdf — where no
        // filename rule can ever fire. The model used to be the only thing that
        // caught these, which meant catching them after they had been sent.
        let body = [evidence.textExcerpt, evidence.ocrText].compactMap { $0 }.joined(separator: "\n")
        if !body.isEmpty {
            for pattern in settings.sensitiveContentPatterns {
                guard matchesWord(pattern, in: body) else { continue }
                return Verdict(isSensitive: true, reason: "contents mention \"\(pattern)\"")
            }

            // A passport's machine-readable zone: `P<INDPENDELA<<SRINIVAS<RAO<<<<`.
            // Four or more `<` in a row occur in nothing else. This is what a
            // certified copy of a passport page looks like once OCR'd, and no word
            // list would ever have named it.
            if body.range(of: "<{4,}", options: .regularExpression) != nil {
                return Verdict(isSensitive: true, reason: "contents carry a passport machine-readable zone")
            }
        }

        // The user's own identifiers — an email, a phone number, an IBAN. If a
        // page mentions one, it is about them, whatever else it says. Matched as
        // plain substrings because each is long and specific; and never seeded in
        // source, only ever in the user's own settings.json.
        let everything = (haystacks + "\n" + body).lowercased()
        for identifier in settings.personalIdentifiers {
            let needle = identifier.lowercased().trimmingCharacters(in: .whitespaces)
            guard needle.count >= 6, everything.contains(needle) else { continue }
            return Verdict(isSensitive: true, reason: "mentions one of your personal identifiers")
        }

        // Hosts are matched as substrings on purpose: "hdfc" should catch
        // netbanking.hdfcbank.com, where a word boundary would not.
        if let host = evidence.sourceHost?.lowercased() {
            for hostPattern in settings.sensitiveHosts {
                let needle = hostPattern.lowercased()
                guard !needle.isEmpty, host.contains(needle) else { continue }
                return Verdict(isSensitive: true, reason: "source host matched \"\(hostPattern)\"")
            }
        }

        // A phone photo of a passport is named IMG_2451.jpg and comes from nowhere,
        // so the patterns above cannot see it. Vision can, from the pixels alone.
        for label in evidence.imageLabels ?? [] {
            guard settings.sensitiveImageLabels.contains(label.label),
                  label.confidence >= settings.sensitiveLabelThreshold else { continue }
            return Verdict(
                isSensitive: true,
                reason: String(format: "image looks like a %@ (%.0f%%)",
                               label.label.replacingOccurrences(of: "_", with: " "),
                               label.confidence * 100)
            )
        }

        return Verdict(isSensitive: false, reason: nil)
    }

    /// Substring matching on short financial words is actively dangerous here:
    /// "chit" is inside architect and Chitragupta, "emi" is inside academic,
    /// chemistry and remind, "tax" is inside taxonomy. Every one of those would be
    /// held as a private financial record and never filed. Matching on word
    /// boundaries instead keeps the short patterns usable.
    private static func matchesWord(_ pattern: String, in rawText: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        // Both sides go through the same normalizer, so a pattern written as
        // "w2" or "steuer-id" still meets a filename written as "W2_2025" or
        // "Steuer-ID".
        let text = opened(rawText)
        let escaped = NSRegularExpression.escapedPattern(for: opened(trimmed))

        // A trailing plural is allowed, or "bank" would miss "banks" and "chit"
        // would miss "Chits-june.png" — a whole-word rule that silently ignores
        // the plural is a trap for anyone writing their own patterns.
        let expression = "(^|[^\\p{L}\\p{N}])\(escaped)(?:e?s)?($|[^\\p{L}\\p{N}])"
        return text.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Opens the word boundaries that filenames hide. Each one cost a real miss:
    ///
    ///   `JaneDoePassport.pdf`   — lower→upper seam; "passport" was invisible
    ///   `rechnung01012026_1.jpeg`   — letter→digit seam; "rechnung" was invisible
    ///   `PPT-Residence_permit.pdf`  — underscore; "residence permit" was invisible
    ///
    /// `application` has none of these seams, so `lic` still cannot match inside
    /// it — the original protection is untouched.
    static func opened(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "(?<=\\p{Ll})(?=\\p{Lu})", with: " ",
                                       options: .regularExpression)
        t = t.replacingOccurrences(of: "(?<=\\p{L})(?=\\p{N})|(?<=\\p{N})(?=\\p{L})", with: " ",
                                   options: .regularExpression)
        t = t.replacingOccurrences(of: "[_.\\-]+", with: " ", options: .regularExpression)
        return t
    }
}
