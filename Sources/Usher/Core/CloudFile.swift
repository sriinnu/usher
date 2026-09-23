import Foundation

/// Most of what lives in iCloud Drive is a placeholder, not a file: the name and
/// size are local, the bytes are not. Reading one without materializing it first
/// gives empty text and an empty OCR pass, which looks exactly like a file with
/// nothing in it — the worst possible failure, because it classifies confidently
/// on no evidence.
enum CloudFile {

    enum Availability {
        case local              // not an iCloud item, or fully downloaded
        case placeholder        // needs downloading before it can be read
        case downloading
    }

    static func availability(of url: URL) -> Availability {
        let keys: Set<URLResourceKey> = [
            .ubiquitousItemDownloadingStatusKey,
            .isUbiquitousItemKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else { return .local }

        switch values.ubiquitousItemDownloadingStatus {
        case .some(.current), .some(.downloaded):
            return .local
        case .some(.notDownloaded):
            return .placeholder
        default:
            return .downloading
        }
    }

    /// Kicks off a download without waiting. Call this across a whole batch first:
    /// iCloud pipelines concurrent requests, and waiting on each file in turn makes
    /// a sweep take minutes it does not need to.
    static func prefetch(_ urls: [URL]) {
        for url in urls where availability(of: url) == .placeholder {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            requestCoordinatedRead(url)
        }
    }

    /// Asks iCloud for the bytes and waits. Returns false on timeout so the caller
    /// can record "not available" rather than classify on nothing.
    static func materialize(_ url: URL,
                            timeout: TimeInterval = 60,
                            pollInterval: TimeInterval = 0.4) async -> Bool {
        guard availability(of: url) != .local else { return true }

        // startDownloadingUbiquitousItem is only a hint — a 54KB file can sit
        // unmaterialized for over 30s on it alone. A coordinated read is what
        // actually forces delivery, so do both and poll for the result.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        requestCoordinatedRead(url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if availability(of: url) == .local { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }

    /// The coordinated read blocks until iCloud delivers, so it runs detached and
    /// the caller polls instead. Nothing is kept: the bytes are mapped and dropped.
    private static func requestCoordinatedRead(_ url: URL) {
        DispatchQueue.global(qos: .utility).async {
            let coordinator = NSFileCoordinator()
            var error: NSError?
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { readURL in
                _ = try? Data(contentsOf: readURL, options: .mappedIfSafe)
            }
        }
    }

    /// Byte size as iCloud reports it, without downloading anything. Used to skip
    /// pulling a 2GB archive down just to read its name.
    static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
        if let total = values?.totalFileSize { return Int64(total) }
        if let size = values?.fileSize { return Int64(size) }
        return 0
    }
}
