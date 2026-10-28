import CoreServices
import Foundation

/// One FSEvents stream over every watched folder. The 2 s latency doubles as the debounce.
final class FolderWatcher {
    private let onChange: @MainActor @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init?(paths: [String], onChange: @escaping @MainActor @Sendable () -> Void) {
        guard !paths.isEmpty else { return nil }
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            let onChange = Unmanaged<FolderWatcher>.fromOpaque(info!).takeUnretainedValue().onChange
            // the stream is scheduled on the main queue
            MainActor.assumeIsolated { onChange() }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
