import Foundation

/// Where "{root}" in a route or rule points, for a given file.
///
/// Every destination used to be an absolute iCloud path, which meant a file
/// found in Google Drive would be moved *to iCloud*. Routes now say
/// `{root}/German`, and each watched folder decides what `{root}` means for the
/// files found in it. Unset, it is the default — iCloud Drive, exactly as
/// before. Set explicitly, destinations resolve inside that root and nowhere
/// else: a Drive watch files back into Drive, never across a library boundary.
enum DestinationRoot {

    static let placeholder = "{root}"

    static func resolve(_ template: String, root: URL) -> URL {
        var path = template
        if path.hasPrefix(placeholder) {
            path = root.path + path.dropFirst(placeholder.count)
        } else if path.contains(placeholder) {
            path = path.replacingOccurrences(of: placeholder, with: root.path)
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// The root for a file: its watched folder's explicit root, else the default.
    static func root(for url: URL, settings: AppSettings) -> URL {
        let target = url.canonicalPath
        var best: (len: Int, root: String?)? = nil
        for w in settings.watchFolders where w.enabled {
            let base = w.url.canonicalPath
            guard target == base || target.hasPrefix(base + "/") else { continue }
            if best == nil || base.count > best!.len { best = (base.count, w.destinationRoot) }
        }
        let chosen = best?.root ?? settings.defaultDestinationRoot
        return URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath)
    }

    /// Every root any watched folder can resolve to — for protecting all of
    /// their destinations from being treated as movable units.
    static func allRoots(settings: AppSettings) -> [URL] {
        var seen = Set<String>(); var out: [URL] = []
        for raw in [settings.defaultDestinationRoot] + settings.watchFolders.compactMap(\.destinationRoot) {
            let u = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            if seen.insert(u.canonicalPath).inserted { out.append(u) }
        }
        return out
    }
}
