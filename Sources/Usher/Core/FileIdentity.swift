import Foundation

extension URL {

    /// Path suitable for deciding whether two URLs are the same file.
    ///
    /// `standardized` resolves `.` and `..` but *not* symlinks, and the two ways a
    /// URL reaches us disagree: `contentsOfDirectory` hands back symlink-resolved
    /// paths (`/private/var/…`) while a URL built by appending components keeps
    /// the unresolved form (`/var/…`). Comparing those as strings says two names
    /// for one file are different files — which made a file its own duplicate and
    /// defeated the already-in-place check that prevents a rename loop.
    var canonicalPath: String {
        resolvingSymlinksInPath().standardized.path
    }

    func isSameFile(as other: URL) -> Bool {
        canonicalPath == other.canonicalPath
    }
}

/// Which file a path held, as opposed to which path. The journal is keyed by
/// path, so a new "invoice.pdf" downloaded where an old one was filed looked
/// already decided and was never picked up. Creation date and size survive a
/// move and a rename, and a new download at the same path has neither.
enum FileIdentity {
    static func of(_ url: URL) -> String? {
        guard !url.hasDirectoryPath,
              let v = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey]),
              let created = v.creationDate, let size = v.fileSize else { return nil }
        return "\(Int(created.timeIntervalSince1970 * 1000))-\(size)"
    }
}
