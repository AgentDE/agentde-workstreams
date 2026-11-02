import AgentDEKit
import CoreServices
import Foundation

/// Reports changed paths under some folders, via FSEvents (file-level events, coalesced over `latency`).
/// The handler runs on `queue`. No polling: the kernel tells us.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init?(paths: [String], latency: TimeInterval = 0.3, queue: DispatchQueue, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            watcher.handler(Array(changed.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// The path with symlinks resolved, as FSEvents reports it (`/tmp` → `/private/tmp`).
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
