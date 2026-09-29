import Foundation

/// Files Usher never looks at. Different from the secret floor and the privacy
/// lists, which *hold* a file and show it in the panel: an ignored file is
/// not read, not journaled and never gets a row. For the things you know you
/// want left exactly where they land — installers, camera dumps, a vendor's
/// key files, a colleague's exports.
///
/// Patterns are shell globs matched against the file or folder name, case
/// insensitively: `*.dmg`, `IMG_*`, `AuthKey_*`, `Screenshot *`.
enum Exclusions {

    static func isIgnored(_ url: URL, settings: AppSettings) -> Bool {
        let name = url.lastPathComponent
        return settings.ignorePatterns.contains { matches($0, name) }
    }

    static func matches(_ pattern: String, _ name: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return false }
        return fnmatch(p, name, FNM_CASEFOLD) == 0
    }
}
