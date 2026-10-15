import CoreServices
import Foundation

/// FSEvents-based watcher for one directory tree. Delivers coalesced changed paths; consumers
/// must re-read the filesystem (notifications are hints, never truth — Bible Part 11 §12).
public final class FileWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable ([String]) -> Void

    private var stream: FSEventStreamRef?
    private let handler: Handler
    private let queue = DispatchQueue(label: "works.c2d.terminal.filewatcher")
    public let root: String

    /// `latency` is the coalescing window in seconds.
    public init(root: String, latency: TimeInterval = 0.3, handler: @escaping Handler) throws {
        self.root = root
        self.handler = handler
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var changed: [String] = []
            for i in 0..<count {
                if let p = cPaths[i] { changed.append(String(cString: p)) }
            }
            watcher.handler(changed)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)   // C string array, not CFTypes
        guard let s = FSEventStreamCreate(nil, callback, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            throw FileWatcherError.streamCreationFailed
        }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
            throw FileWatcherError.streamStartFailed
        }
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

public enum FileWatcherError: Error, Sendable {
    case streamCreationFailed, streamStartFailed
}
