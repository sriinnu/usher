import Foundation
import CryptoKit

/// A short hash of everything that can change Jev's *answer*: how evidence is
/// read and asked about, routes.json, rules.json, the privacy lists and the
/// model. A journal entry stamped with a different fingerprint was answered by
/// a different app, and is worth asking again.
///
/// Deliberately not in here: the thresholds and dry run. They change what is
/// *done* with an answer, not the answer, and the journal already holds the
/// answer — `Pipeline.reapplyPolicy` re-decides from it without a single call.
/// Hashing them made turning dry run off re-send every file ever previewed.
enum ConfigFingerprint {

    /// Bump when a change to evidence extraction, the questions, the name
    /// candidates or the local rules engine could change an answer. This
    /// replaced the binary's modification date, which changed on every
    /// rebuild — a README edit made every unresolved file look new, and with
    /// Google Drive watched that is thousands of calls per build.
    ///
    /// 2 — secret floor by name and by content; archives other than zip listed.
    static let logicVersion = 2

    /// Cached, and invalidated whenever routes, rules or settings are reloaded
    /// or saved. A value computed once per process meant Reload never counted
    /// as a change, so a file capped at two attempts stayed skipped for a day
    /// after the user added the very route that would place it.
    static var current: String {
        if let c = cached { return c }
        let v = compute(); cached = v; return v
    }
    private static var cached: String?
    static func invalidate() { cached = nil }

    private static func compute() -> String {
        var hasher = SHA256()
        func feed(_ s: String) { hasher.update(data: Data(s.utf8)); hasher.update(data: Data([0])) }

        feed("logic:\(logicVersion)")
        for file in [Paths.routes, Paths.rules] {
            if let data = try? Data(contentsOf: file) { hasher.update(data: data); hasher.update(data: Data([0])) }
        }
        if let data = try? Data(contentsOf: Paths.settings),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            feed(settings.sensitivePatterns.joined(separator: "|"))
            feed(settings.sensitiveHosts.joined(separator: "|"))
            feed(settings.sensitiveContentPatterns.joined(separator: "|"))
            feed(settings.sensitiveExtensions.joined(separator: "|"))
            feed(settings.sensitiveImageLabels.joined(separator: "|"))
            feed("\(settings.personalIdentifiers.count)")   // count only; never the values
            feed("model:\(settings.model)")
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
