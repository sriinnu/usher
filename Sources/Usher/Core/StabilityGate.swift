import Foundation

/// Browsers write downloads incrementally and under a placeholder name. Nothing
/// downstream runs until a file has stopped growing and lost its partial suffix.
enum StabilityGate {

    /// Suffixes browsers use while a download is still running.
    static let partialExtensions: Set<String> = [
        "crdownload",   // Chrome, Edge, Brave
        "download",     // Safari
        "part",         // Firefox
        "partial",
        "opdownload",   // Opera
        "tmp"
    ]

    static let ignoredNames: Set<String> = [".DS_Store", ".localized"]

    /// Directories that are never a source of downloads, whatever they contain.
    /// A recursive watch on a folder with a source tree in it otherwise fires an
    /// event for every file in every node_modules — 66,933 of them in one case —
    /// and a cloud drive's own Trash is exactly the kind of place password-manager
    /// exports end up.
    static let ignoredDirectories: Set<String> = [
        ".Trash", ".git", ".svn", ".hg", ".build", ".swiftpm",
        "node_modules", "DerivedData", "Pods", "Carthage", ".venv", "venv",
        "__pycache__", ".cache", "Caches", "target", "dist", ".next", ".nuxt"
    ]

    static func isPartial(_ url: URL) -> Bool {
        partialExtensions.contains(url.pathExtension.lowercased())
    }

    static func shouldIgnore(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if ignoredNames.contains(name) { return true }
        if name.hasPrefix(".") { return true }
        // Any ancestor on the skip list disqualifies the whole subtree.
        for component in url.pathComponents.dropLast()
        where ignoredDirectories.contains(component) {
            return true
        }
        return false
    }

    /// Polls until size and mtime hold steady across two consecutive reads.
    /// Returns nil if the file disappears or never settles.
    static func waitUntilStable(_ url: URL,
                                pollInterval: TimeInterval = 0.7,
                                stableReadsRequired: Int = 2,
                                timeout: TimeInterval = 300) async -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSignature: String?
        var stableReads = 0

        while Date() < deadline {
            // A sibling placeholder means the browser is still writing the real file.
            if hasPartialSibling(url) {
                stableReads = 0
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                continue
            }

            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return nil  // gone, or renamed out from under us
            }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            let signature = "\(size)/\(mtime)"

            // A zero-byte file that is not changing is stable too. Requiring
            // size > 0 made every empty file poll for the full timeout, pinning
            // one of the three catch-up slots for five minutes each.
            let quietForAWhile = Date().timeIntervalSince1970 - mtime > 5
            if signature == lastSignature, size > 0 || quietForAWhile {
                stableReads += 1
                if stableReads >= stableReadsRequired { return url }
            } else {
                stableReads = 0
                lastSignature = signature
            }

            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return nil
    }

    /// `report.pdf` is not done while `report.pdf.crdownload` still exists.
    private static func hasPartialSibling(_ url: URL) -> Bool {
        partialExtensions.contains {
            FileManager.default.fileExists(atPath: url.path + "." + $0)
        }
    }
}
