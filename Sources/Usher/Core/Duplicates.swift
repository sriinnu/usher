import Foundation
import CryptoKit

/// Collision handling that does not make the problem worse.
///
/// The naive behaviour — append " 2" when a name is taken — is how a folder ends
/// up with four files called `hdfc-filled-application`, three of which are the
/// same bytes and one of which is not. Before any move, the destination is checked
/// for a file that is byte-identical to the incoming one. If there is one, the
/// incoming file is a duplicate and is set aside rather than filed alongside.
enum Duplicates {

    enum Verdict {
        /// Nothing at the destination matches; file it normally.
        case unique
        /// An identical file is already filed here.
        case duplicateOf(URL)
    }

    /// Compares against every file in the destination folder that shares a size.
    /// Size is free; hashing only happens for same-size candidates, and a folder
    /// rarely holds more than one or two.
    static func check(_ source: URL, against folder: URL) -> Verdict {
        guard let sourceSize = size(of: source), sourceSize > 0 else { return .unique }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .totalFileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let sameSize = entries.filter { candidate in
            guard !candidate.hasDirectoryPath else { return false }
            guard !candidate.isSameFile(as: source) else { return false }
            return size(of: candidate) == sourceSize
        }
        guard !sameSize.isEmpty else { return .unique }

        // An iCloud placeholder cannot be hashed, so it cannot be compared.
        // Treating it as "not a duplicate" is the safe direction: worst case we
        // keep two copies, rather than discarding something we never read.
        guard CloudFile.availability(of: source) == .local,
              let sourceHash = sha256(source) else { return .unique }

        for candidate in sameSize {
            guard CloudFile.availability(of: candidate) == .local,
                  let hash = sha256(candidate), hash == sourceHash else { continue }
            return .duplicateOf(candidate)
        }
        return .unique
    }

    static func size(of url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.totalFileSizeKey, .fileSizeKey])
        return values?.totalFileSize ?? values?.fileSize
    }

    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
