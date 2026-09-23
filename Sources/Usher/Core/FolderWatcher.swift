import Foundation
import CoreServices

/// Thin FSEvents wrapper. One stream covers every watched folder; callers get
/// deduplicated file paths on a background queue.
final class FolderWatcher {

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.sriinnu.usher.watcher")
    private let onChange: ([URL]) -> Void

    init(onChange: @escaping ([URL]) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    func start(folders: [WatchFolder]) {
        stop()
        let active = folders.filter { $0.enabled && $0.exists }
        guard !active.isEmpty else { return }

        // Non-recursive folders still receive subtree events from FSEvents, so we
        // filter by depth on the way out.
        let allowedParents = Set(active.filter { !$0.recursive }.map { $0.url.standardized.path })
        let recursiveRoots = active.filter(\.recursive).map { $0.url.standardized.path }

        let context = Context(allowedParents: allowedParents,
                              recursiveRoots: recursiveRoots,
                              onChange: onChange)
        let boxed = Unmanaged.passRetained(context).toOpaque()
        var streamContext = FSEventStreamContext(
            version: 0,
            info: boxed,
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<Context>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let paths = active.map { $0.url.path } as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer)

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &streamContext,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.6,                      // coalesce bursts; downloads arrive in chunks
            flags
        ) else {
            Unmanaged<Context>.fromOpaque(boxed).release()
            return
        }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Carried through the C callback's `info` pointer.
    private final class Context {
        let allowedParents: Set<String>
        let recursiveRoots: [String]
        let onChange: ([URL]) -> Void

        init(allowedParents: Set<String>, recursiveRoots: [String], onChange: @escaping ([URL]) -> Void) {
            self.allowedParents = allowedParents
            self.recursiveRoots = recursiveRoots
            self.onChange = onChange
        }

        func accepts(_ path: String) -> Bool {
            let parent = (path as NSString).deletingLastPathComponent
            if allowedParents.contains(parent) { return true }
            return recursiveRoots.contains { path.hasPrefix($0 + "/") }
        }
    }

    private let eventCallback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

        var hits: [URL] = []
        for i in 0..<count {
            let flags = Int(eventFlags[i])
            // Only creations and renames matter: a download lands as one or the other.
            let interesting = flags & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
            let isFile = flags & kFSEventStreamEventFlagItemIsFile != 0
            guard interesting, isFile else { continue }

            let path = paths[i]
            guard context.accepts(path) else { continue }
            hits.append(URL(fileURLWithPath: path))
        }

        guard !hits.isEmpty else { return }
        context.onChange(hits)
    }
}
