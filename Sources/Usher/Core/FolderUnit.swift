import Foundation

/// A directory that is one thing — an unpacked repo, a font family, a glyph
/// pack, the audio for one course book — and must be filed as one thing.
///
/// `Downloads/Dev/Hasklig-main` is 47,348 files. Classifying it per file is
/// 47,348 API calls that all say "part of a font"; classifying the folder is
/// one call that says "a font". Units are recognised, described from their
/// listing, routed through the same rules and filter as a file, and then moved
/// whole. A folder move is never automatic: it always waits for approval.
enum FolderUnit {

    /// Suffixes and shapes that mean "this folder is one downloaded thing".
    private static let unitNamePatterns = [
        #"-(main|master|dev|develop|trunk|release)$"#,     // GitHub archive exports
        #"[-_ ](pack|kit|bundle|assets)$"#,
        #"[-_ ]v?\d+\.\d+(\.\d+)?( \d+)?$"#,                // "Berkeley Mono v2.002", "… 2"
        #"^gh_\d"#, #"^(node|python|go)-?\d"#
    ]

    private static let repoMarkers: Set<String> = [
        ".git", "package.json", "Package.swift", "Cargo.toml", "pyproject.toml",
        "setup.py", "go.mod", "pom.xml", "build.gradle", "Gemfile", "composer.json",
        "Makefile", "CMakeLists.txt", "README.md", "LICENSE", "LICENSE.md"
    ]

    /// Extensions whose dominance makes a folder a unit. Photos are deliberately
    /// absent: a folder of 4,000 JPEGs is the Photos phase, not a download.
    private static let unitExtensions: Set<String> = [
        "ttf", "otf", "woff", "woff2",                      // fonts
        "mp3", "m4a", "flac", "wav", "aac",                 // an album, a course's audio
        "svg", "glyph", "sketch", "fig",                    // design packs
        "swift", "js", "ts", "py", "rs", "go", "java", "c", "h", "cpp", "m"   // source
    ]

    /// Directories that are never a unit and never walked.
    static func isExcluded(_ url: URL, settings: AppSettings) -> Bool {
        let name = url.lastPathComponent
        if StabilityGate.shouldIgnore(url) { return true }
        if url.pathExtension.lowercased() == "app" { return true }            // a bundle, not a download
        if name.hasSuffix(".download") || name.hasSuffix(".crdownload") { return true }
        let duplicates = URL(fileURLWithPath: (settings.duplicatesFolder as NSString).expandingTildeInPath)
        if url.isSameFile(as: duplicates) { return true }
        // A folder named for keys or secrets is treated exactly like a key file.
        if name.range(of: #"(^|[-_ ])(keys?|secrets?|credentials?|certs?|vault)([-_ ]|$)"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return false
    }

    struct Shape {
        var fileCount: Int
        var dominantExtension: String?
        var dominantShare: Double
        var hasRepoMarker: Bool
        var sample: [String]      // relative paths, first N
        var bytes: Int64
    }

    /// One bounded walk: enough to say what the folder is, never the whole tree.
    static func shape(of url: URL, sampleLimit: Int = 60, walkLimit: Int = 600) -> Shape {
        let manager = FileManager.default
        var counts: [String: Int] = [:]
        var files = 0, bytes: Int64 = 0
        var sample: [String] = []
        var repo = false

        if let top = try? manager.contentsOfDirectory(atPath: url.path) {
            repo = top.contains { repoMarkers.contains($0) }
        }
        // The enumerator hands back symlink-resolved paths (/private/var/…) while
        // the folder URL may not be; strip the prefix on canonical forms or the
        // sample ends up as absolute paths instead of relative ones.
        let base = url.canonicalPath + "/"
        if let e = manager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                      options: [.skipsHiddenFiles]) {
            for case let item as URL in e {
                if files >= walkLimit { break }
                guard !item.hasDirectoryPath else { continue }
                files += 1
                let ext = item.pathExtension.lowercased()
                if !ext.isEmpty { counts[ext, default: 0] += 1 }
                bytes += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                if sample.count < sampleLimit {
                    sample.append(item.canonicalPath.replacingOccurrences(of: base, with: ""))
                }
            }
        }
        let top = counts.max { $0.value < $1.value }
        return Shape(fileCount: files,
                     dominantExtension: top?.key,
                     dominantShare: files > 0 ? Double(top?.value ?? 0) / Double(files) : 0,
                     hasRepoMarker: repo,
                     sample: sample,
                     bytes: bytes)
    }

    static func isUnit(_ url: URL, shape: Shape) -> Bool {
        // Nothing to file. `moltbot-main` was an empty folder matching the
        // "-main" name pattern, so it went to the API as "folder of 0 files"
        // and came back unsorted — twice per config change, forever.
        guard shape.fileCount > 0 else { return false }
        let name = url.lastPathComponent
        if shape.hasRepoMarker { return true }
        for p in unitNamePatterns where name.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if shape.fileCount >= 15, let ext = shape.dominantExtension,
           unitExtensions.contains(ext), shape.dominantShare >= 0.6 {
            return true
        }
        return false
    }
}
