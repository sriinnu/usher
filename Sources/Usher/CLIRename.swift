import Foundation
import CryptoKit

/// Bulk filename cleanup for files that are already filed.
///
/// Library dumps carry the whole catalogue record in the name — mirror domains,
/// ISBNs, content hashes, publisher strings. Renaming is pure code: `BookName`
/// proposes the tidy spellings and the first one wins. No model call, so this runs
/// over hundreds of files for free and never sends anything anywhere.
enum CLIRename {

    static func run(arguments: [String]) async -> Int32 {
        var roots: [URL] = []
        var apply = false
        var recursive = false

        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--apply":
                apply = true
            case "--recursive", "-r":
                recursive = true
            case "--dir":
                i += 1
                guard i < arguments.count else {
                    FileHandle.standardError.write(Data("--dir needs a folder\n".utf8))
                    return 2
                }
                roots.append(URL(fileURLWithPath: (arguments[i] as NSString).expandingTildeInPath))
            case "--help", "-h":
                printUsage()
                return 0
            default:
                roots.append(URL(fileURLWithPath: (arguments[i] as NSString).expandingTildeInPath))
            }
            i += 1
        }

        guard !roots.isEmpty else {
            printUsage()
            return 2
        }

        var files: [URL] = []
        for root in roots {
            files += collect(root, recursive: recursive)
        }

        let settings = (try? JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: Paths.settings)))
            ?? .default
        // Applying writes the rename log, and the log is encrypted: no key, no
        // renames, rather than an undo list written in the clear.
        let logKey = apply ? LogCipher.key() : nil
        if apply, logKey == nil {
            print("The rename log is encrypted and its key could not be read from the keychain. Nothing renamed.")
            return 1
        }
        var renamed = 0, skipped = 0, failed = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            // Never touch a vault, not even its name.
            if SecretFormats.isSecret(file, settings: settings) { skipped += 1; continue }
            if Exclusions.isIgnored(file, settings: settings) { skipped += 1; continue }
            // stripped, not candidates: bulk rename never reorders a name.
            guard let cleaned = BookName.stripped(for: file.lastPathComponent),
                  cleaned != file.lastPathComponent else {
                skipped += 1
                continue
            }

            let target = file.deletingLastPathComponent().appendingPathComponent(cleaned)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                print("  SKIP  \(file.lastPathComponent)")
                print("        target name already taken: \(cleaned)")
                skipped += 1
                continue
            }

            print("  \(apply ? "RENAME" : "would")  \(file.lastPathComponent)")
            print("      →   \(cleaned)")

            if apply {
                do {
                    try FileManager.default.moveItem(at: file, to: target)
                    renamed += 1
                    if let logKey { logRename(from: file, to: target, key: logKey) }
                } catch {
                    print("        FAILED: \(error.localizedDescription)")
                    failed += 1
                }
            } else {
                renamed += 1
            }
        }

        print("")
        if apply {
            print("\(renamed) renamed, \(skipped) left alone, \(failed) failed")
        } else {
            print("\(renamed) would be renamed, \(skipped) left alone")
            print("re-run with --apply to do it")
        }
        return 0
    }

    /// One encrypted line per applied rename, so a pass over hundreds of files
    /// can be reversed: `Usher log renames | jq -r '"\(.to)\t\(.from)"'` is
    /// the undo list.
    private static func logRename(from: URL, to: URL, key: SymmetricKey) {
        let line: [String: String] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "from": from.path, "to": to.path
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: line) else { return }
        LogCipher.append(data, to: Paths.renames, key: key)
    }

    private static func collect(_ root: URL, recursive: Bool) -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [root] }

        if recursive {
            guard let e = manager.enumerator(at: root,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
            return e.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }
        }

        let contents = (try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return contents.filter { !$0.hasDirectoryPath }
    }

    private static func printUsage() {
        print("""
        Usage:
          Usher rename --dir <folder>              show what would change
          Usher rename --dir <folder> --apply      actually rename
          Usher rename --dir <folder> -r --apply   include subfolders

        Strips mirror names (z-library, libgen, Anna's Archive, PDF Room), ISBNs,
        content hashes and publisher strings from filenames. Nothing is sent
        anywhere and nothing is moved between folders — names only.
        """)
    }
}
