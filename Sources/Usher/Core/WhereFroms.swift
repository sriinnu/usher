import Foundation

/// macOS stamps downloads with `com.apple.metadata:kMDItemWhereFroms`, a binary
/// plist array of [download URL, referring page URL]. It is the single most
/// useful signal we get for free.
enum WhereFroms {

    static func read(_ url: URL) -> [String] {
        let attribute = "com.apple.metadata:kMDItemWhereFroms"
        let size = url.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else { return -1 }
            return getxattr(path, attribute, nil, 0, 0, 0)
        }
        guard size > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        let read = url.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else { return -1 }
            return getxattr(path, attribute, &buffer, size, 0, 0)
        }
        guard read > 0 else { return [] }

        let data = Data(buffer[0..<read])
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let entries = plist as? [String] else { return [] }
        return entries.filter { !$0.isEmpty }
    }

    /// Host of the first usable entry, for both routing hints and the sensitive filter.
    static func host(from entries: [String]) -> String? {
        for entry in entries {
            if let host = URL(string: entry)?.host, !host.isEmpty { return host }
        }
        return nil
    }
}
