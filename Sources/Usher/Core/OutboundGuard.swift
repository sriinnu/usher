import Foundation

/// Everything that stands between a file and the network, in one place.
///
/// The secret floor used to screen the text excerpt and OCR — but the request
/// carries more than that: the source URL (a presigned S3 link holds a live
/// credential in its query string), archive entry names, PDF metadata, the
/// sampled file names of a folder unit, and in stage two the names of files
/// already filed in your destination folders, where rules put private
/// documents. A security review found all of those going out unscreened.
///
/// Two layers:
/// - `prepare` narrows the evidence before a request is built: the full format
///   floor on the filename, secret-named archive entries and name candidates
///   dropped, query strings and fragments cut from URLs.
/// - `screen` runs on the exact bytes of the request body, in `JevClient.ask`,
///   the last line before the network. Whatever path a request took, and
///   whatever a future caller adds to it, those bytes are what get checked.
enum OutboundGuard {

    static func prepare(_ evidence: Evidence, settings: AppSettings) throws -> Evidence {
        let named = URL(fileURLWithPath: "/" + evidence.filename)
        if SecretFormats.isSecret(named, settings: settings) {
            throw JevError.refusedSecret("a secret, by its name or format")
        }
        if let kind = SecretContent.detect(evidence) {
            throw JevError.refusedSecret(kind)
        }
        var e = evidence
        e.sourceURL = strippedURL(e.sourceURL)
        e.referrerURL = strippedURL(e.referrerURL)
        e.archiveEntries = e.archiveEntries.map { screenNames($0, settings: settings) }
        e.nameCandidates = screenNames(e.nameCandidates, settings: settings)
        return e
    }

    /// Scheme, host and path. Query strings and fragments are where signed
    /// URLs keep their credentials, and where tracking keeps everything else.
    static func strippedURL(_ s: String?) -> String? {
        guard let s, var parts = URLComponents(string: s) else { return s }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? s
    }

    /// File names that may appear in a request: not secrets by name or format,
    /// not matching your privacy patterns.
    static func screenNames(_ names: [String], settings: AppSettings) -> [String] {
        names.filter { name in
            let last = (name as NSString).lastPathComponent
            return !SecretFormats.isSecret(URL(fileURLWithPath: "/" + last), settings: settings)
                && !SensitiveFilter.nameIsSensitive(last, settings: settings)
        }
    }

    /// The last check, on the serialized request itself.
    static func screen(body: Data) throws {
        guard let text = String(data: body, encoding: .utf8) else { return }
        // JSON escapes newlines and slashes; undo that so line-based and
        // PEM-shaped patterns see what the file actually said.
        let readable = text.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\\"", with: "\"")
        if let kind = SecretContent.detect(text: readable) {
            throw JevError.refusedSecret(kind)
        }
    }
}
