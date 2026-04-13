import Foundation

struct ScanFailure {
    let path: String
    let reason: String
}

/// Scans folders recursively on demand. No live FSEvents watching.
final class FolderScanner {
    private let libraryService: LibraryService

    /// Called on the MainActor when a scan begins.
    var onScanStarted: ((String) -> Void)?
    /// Called on the MainActor when a scan completes.
    var onScanFinished: ((String) -> Void)?
    /// Called on the MainActor every 25 files with (currentFilePath, scannedCount).
    var onScanProgress: ((String, Int) -> Void)?

    /// URL to append scan error logs to. Set by AppEnvironment to the DB directory.
    var logFileURL: URL?

    init(libraryService: LibraryService) {
        self.libraryService = libraryService
    }

    /// Scans a folder for new/modified files (skips unchanged). Used when adding a folder.
    func scan(path: String) {
        Task.detached(priority: .utility) { [weak self] in
            await self?.scanFolder(path: path, force: false)
        }
    }

    /// Force re-ingests every audio file, ignoring the mtime cache.
    func rescan(path: String) async {
        await scanFolder(path: path, force: true)
    }

    // MARK: - Private

    private func scanFolder(path: String, force: Bool) async {
        await MainActor.run { onScanStarted?(path) }
        print("[FolderScanner] scanFolder start: \(path) force=\(force)")

        let fm  = FileManager.default
        let url = URL(fileURLWithPath: path)
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            print("[FolderScanner] enumerator nil — cannot access path")
            await MainActor.run { onScanFinished?(path) }
            return
        }

        // Pre-load all known mtimes: one SELECT instead of one per file.
        let knownMtimes: [String: Double] = force ? [:] : ((try? libraryService.fetchAllMtimes()) ?? [:])

        var count = 0
        var audioCount = 0
        var skipped = 0
        var failures: [ScanFailure] = []

        for case let fileURL as URL in enumerator {
            count += 1
            guard isAudioFile(fileURL) else { continue }
            audioCount += 1

            // Fast path: skip unchanged files.
            if !force,
               let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let mtime = attrs[.modificationDate] as? Date,
               knownMtimes[fileURL.path] == mtime.timeIntervalSince1970 {
                skipped += 1
                continue
            }

            do {
                try await libraryService.ingestFile(at: fileURL, force: force)
            } catch {
                failures.append(ScanFailure(path: fileURL.path, reason: error.localizedDescription))
                print("[FolderScanner] skip \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }

            if audioCount % 200 == 0 {
                let p = fileURL.path
                let n = audioCount
                await MainActor.run { onScanProgress?(p, n) }
            }
        }

        let ingested = audioCount - skipped - failures.count
        print("[FolderScanner] done — \(count) visited, \(skipped) unchanged, \(ingested) ingested, \(failures.count) errors")
        writeLog(scanPath: path, failures: failures)
        await MainActor.run { onScanFinished?(path) }
    }

    private func writeLog(scanPath: String, failures: [ScanFailure]) {
        guard !failures.isEmpty, let logURL = logFileURL else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        var lines = ["=== Scan: \(scanPath)  @  \(timestamp) ==="]
        for f in failures {
            lines.append("  \(f.path)")
            lines.append("    \(f.reason)")
        }
        lines.append("")
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
        print("[FolderScanner] wrote \(failures.count) error(s) to \(logURL.lastPathComponent)")
    }

    private func isAudioFile(_ url: URL) -> Bool {
        ["wav", "aif", "aiff"].contains(url.pathExtension.lowercased())
    }
}
