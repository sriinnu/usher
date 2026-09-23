import Foundation

/// All filesystem mutation lives here. Nothing is ever overwritten and nothing is
/// ever deleted: a name collision gets a numeric suffix instead.
enum Mover {

    struct Plan {
        var source: URL
        var destination: URL
    }

    /// Builds the final path without touching disk, so dry-run shows the truth.
    static func plan(source: URL,
                     folder: URL,
                     template: String,
                     chosenName: String,
                     evidence: Evidence) -> Plan {
        let named = applyTemplate(template, chosenName: chosenName, evidence: evidence)
        let target = folder.appendingPathComponent(named)
        // The file itself is not a name collision. Without this, a file already
        // sitting in its correct folder gets renamed to "… 2", which fires another
        // event, which renames it again.
        return Plan(source: source, destination: uniquePath(target, ignoring: source))
    }

    /// True when acting would achieve nothing: right folder, right name already.
    static func isNoOp(_ plan: Plan) -> Bool {
        plan.source.isSameFile(as: plan.destination)
    }

    enum Refusal: LocalizedError {
        case missingFolder(String)
        var errorDescription: String? {
            switch self {
            case .missingFolder(let name): return "The folder \"\(name)\" does not exist, and Usher does not create folders without asking."
            }
        }
    }

    /// Creating a folder is a decision, so it has to be asked for. Every apply
    /// used to create whatever was missing: a route whose folder had been
    /// renamed, or a destination root on a drive that was not mounted, got a
    /// fresh local tree without anyone agreeing to it.
    @discardableResult
    static func apply(_ plan: Plan, createFolders: Bool = false) throws -> URL {
        let directory = plan.destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            guard createFolders else { throw Refusal.missingFolder(directory.lastPathComponent) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Re-resolve in case something landed there between plan and apply.
        let final = uniquePath(plan.destination)
        try FileManager.default.moveItem(at: plan.source, to: final)
        return final
    }

    /// To the Trash, never rm: the Trash copy is the undo.
    static func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let trashed = result as URL? else {
            throw NSError(domain: "Usher", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Trash did not report where the file went."])
        }
        return trashed
    }

    static func undo(from: URL, to: URL) throws -> URL {
        let directory = to.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let final = uniquePath(to)
        try FileManager.default.moveItem(at: from, to: final)
        return final
    }

    // MARK: - Naming

    private static func applyTemplate(_ template: String, chosenName: String, evidence: Evidence) -> String {
        // Mirror junk comes off unconditionally, whatever name was chosen. The
        // model picks which name says what the file is; it does not get a vote on
        // whether "(z-library.sk, 1lib.sk, z-lib.sk)" survives. A file was filed
        // with that still attached because the original name was one of the
        // options and nothing on this path cleaned it.
        // A folder has no extension. "Berkeley Mono v2.002" is not a file called
        // "Berkeley Mono v2" of type "002", and "gh_2.86.0_macOS_amd64" is not
        // ".0_macOS_amd64" — both were about to be renamed on approval.
        if evidence.isDirectory {
            return sanitize(template
                .replacingOccurrences(of: "{name}", with: chosenName)
                .replacingOccurrences(of: ".{ext}", with: "")
                .replacingOccurrences(of: "{ext}", with: ""))
        }
        let cleanedName = BookName.stripped(for: chosenName) ?? chosenName
        let base = (cleanedName as NSString).deletingPathExtension
        var ext = (cleanedName as NSString).pathExtension
        if ext.isEmpty { ext = evidence.ext }

        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: now)
        formatter.dateFormat = "yyyy"
        let year = formatter.string(from: now)
        formatter.dateFormat = "MM"
        let month = formatter.string(from: now)

        var result = template
            .replacingOccurrences(of: "{name}", with: base)
            .replacingOccurrences(of: "{ext}", with: ext)
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{yyyy}", with: year)
            .replacingOccurrences(of: "{mm}", with: month)
            .replacingOccurrences(of: "{source_host}", with: evidence.sourceHost ?? "local")

        // A template ending in a bare dot means the extension was empty.
        if result.hasSuffix(".") { result.removeLast() }
        return sanitize(result)
    }

    private static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\u{0}:")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "-")
        return String(cleaned.prefix(200))
    }

    private static func uniquePath(_ url: URL, ignoring source: URL? = nil) -> URL {
        // A file is never a collision with itself.
        if let source, source.isSameFile(as: url) { return url }
        guard FileManager.default.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        for n in 2...999 {
            let candidate = ext.isEmpty
                ? directory.appendingPathComponent("\(base) \(n)")
                : directory.appendingPathComponent("\(base) \(n).\(ext)")
            if let source, source.isSameFile(as: candidate) { return candidate }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(base) \(UUID().uuidString.prefix(8)).\(ext)")
    }
}
