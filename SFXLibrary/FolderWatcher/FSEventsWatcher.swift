import Foundation
import CoreServices

final class FSEventsWatcher {
    typealias Callback = (_ paths: [String], _ flags: [FSEventStreamEventFlags]) -> Void

    private var stream: FSEventStreamRef?
    private let callback: Callback
    private let queue = DispatchQueue(label: "com.sfxlibrary.fsevents", qos: .utility)

    init(paths: [String], latency: CFTimeInterval = 1.0, callback: @escaping Callback) {
        self.callback = callback

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let c: FSEventStreamCallback = { _, info, count, pathsPtr, flagsPtr, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths  = unsafeBitCast(pathsPtr, to: NSArray.self) as! [String]
            let flags  = Array(UnsafeBufferPointer(start: flagsPtr, count: count))
            watcher.callback(paths, flags)
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault, c, &ctx,
            paths as CFArray,
            FSEventStreamEventId(UInt64.max), // kFSEventsCurrentEventId — start from now
            latency,
            flags)

        if let s = stream {
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
        }
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}

extension FSEventStreamEventFlags {
    var isCreated:  Bool { self & UInt32(kFSEventStreamEventFlagItemCreated)  != 0 }
    var isRemoved:  Bool { self & UInt32(kFSEventStreamEventFlagItemRemoved)  != 0 }
    var isModified: Bool { self & UInt32(kFSEventStreamEventFlagItemModified) != 0 }
    var isRenamed:  Bool { self & UInt32(kFSEventStreamEventFlagItemRenamed)  != 0 }
}
