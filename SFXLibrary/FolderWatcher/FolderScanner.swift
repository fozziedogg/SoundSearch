import Foundation
import AVFoundation

/// Scans folders recursively and keeps the database in sync via FSEvents.
final class FolderScanner {
    private let libraryService: LibraryService
    private var watchers: [String: FSEventsWatcher] = [:]

    /// Called on the MainActor when a full folder scan begins.
    var onScanStarted: ((String) -> Void)?
    /// Called on the MainActor when a full folder scan completes.
    var onScanFinished: ((String) -> Void)?

    init(libraryService: LibraryService) {
        self.libraryService = libraryService
    }

    /// Perform an initial full scan of a folder and start watching it for changes.
    func startWatching(path: String) {
        guard watchers[path] == nil else { return }
        print("[FolderScanner] startWatching: \(path)")

        // Full scan on background thread
        Task.detached(priority: .utility) { [weak self] in
            await self?.scanFolder(path: path, force: false)
        }

        // Live watcher
        watchers[path] = FSEventsWatcher(paths: [path]) { [weak self] paths, flags in
            self?.handleEvents(paths: paths, flags: flags)
        }
    }

    func stopWatching(path: String) {
        watchers.removeValue(forKey: path)
    }

    func stopAll() {
        watchers.removeAll()
    }

    /// Force re-ingests every audio file in the folder, ignoring mtime cache.
    func rescan(path: String) async {
        await scanFolder(path: path, force: true)
    }

    // MARK: - Private

    private func scanFolder(path: String, force: Bool) async {
        await MainActor.run { onScanStarted?(path) }
        print("[FolderScanner] scanFolder start: \(path)")
        let fm  = FileManager.default
        let url = URL(fileURLWithPath: path)
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            print("[FolderScanner] enumerator is nil — cannot access path")
            return
        }

        var count = 0
        var audioCount = 0
        for case let fileURL as URL in enumerator {
            count += 1
            guard isAudioFile(fileURL) else { continue }
            audioCount += 1
            if audioCount <= 3 { print("[FolderScanner] found audio file: \(fileURL.lastPathComponent)") }
            await libraryService.ingestFile(at: fileURL, force: force)
        }
        print("[FolderScanner] scanFolder done — \(count) files scanned, \(audioCount) audio files ingested")
        await MainActor.run { onScanFinished?(path) }
    }

    private func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        for (path, flag) in zip(paths, flags) {
            let url = URL(fileURLWithPath: path)
            guard isAudioFile(url) else { continue }

            if flag.isCreated || flag.isModified {
                Task.detached(priority: .utility) { [weak self] in
                    await self?.libraryService.ingestFile(at: url)
                }
            } else if flag.isRemoved {
                Task.detached(priority: .utility) { [weak self] in
                    await self?.libraryService.removeFile(at: url)
                }
            }
        }
    }

    private func isAudioFile(_ url: URL) -> Bool {
        ["wav", "aif", "aiff"].contains(url.pathExtension.lowercased())
    }
}
