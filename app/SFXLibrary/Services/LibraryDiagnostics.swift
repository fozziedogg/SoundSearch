import Foundation

/// Path/volume diagnostics for the "database moved to another system" failure mode.
///
/// The library stores absolute POSIX paths as row identity (`audio_files.file_url`,
/// `watched_folders.path`, `project_files.file_url`). Those paths are only stable while
/// the volume keeps mounting at the same point. When a volume remounts as
/// `/Volumes/NAME-1` — or the database is carried to a different machine — every path
/// in the database misses, the mtime skip-cache never hits, and the scanner re-ingests
/// the entire library.
///
/// Everything here writes through `SFXAudioLog` so path and audio diagnostics land in
/// the same per-session file under `<database dir>/Debug Logs/`.
enum LibraryDiagnostics {

    static func log(_ message: String) {
        SFXAudioLog.write("[Paths] \(message)")
    }

    // MARK: - Volume identity

    /// Volume identity for a path, resolved from the nearest ancestor that exists.
    /// A missing leaf still reports its volume as long as the mount point is present.
    struct VolumeInfo {
        var exists: Bool
        /// Deepest ancestor of the queried path that exists on disk (may be the path itself).
        var existingAncestor: String?
        var volumeName: String?
        var volumeUUID: String?
        var mountPoint: String?
        var isRemovable: Bool?
        var isNetwork: Bool?

        var summary: String {
            var parts: [String] = []
            parts.append(exists ? "exists=YES" : "exists=NO")
            if !exists, let a = existingAncestor { parts.append("deepestExistingAncestor=\(a)") }
            parts.append("volume=\(volumeName ?? "?")")
            parts.append("mount=\(mountPoint ?? "?")")
            parts.append("uuid=\(volumeUUID ?? "?")")
            if let isNetwork   { parts.append("network=\(isNetwork)") }
            if let isRemovable { parts.append("removable=\(isRemovable)") }
            return parts.joined(separator: "  ")
        }
    }

    private static let volumeKeys: Set<URLResourceKey> = [
        .volumeNameKey, .volumeURLKey, .volumeUUIDStringKey,
        .volumeIsRemovableKey, .isVolumeKey,
    ]

    static func volumeInfo(for path: String) -> VolumeInfo {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: path)

        // Walk up until something exists — a missing leaf under a mounted volume is a
        // very different problem from a volume that is not mounted at all.
        var probe = URL(fileURLWithPath: path)
        var ancestor: String? = nil
        while true {
            if fm.fileExists(atPath: probe.path) { ancestor = probe.path; break }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }

        var info = VolumeInfo(exists: exists, existingAncestor: exists ? nil : ancestor,
                              volumeName: nil, volumeUUID: nil, mountPoint: nil,
                              isRemovable: nil, isNetwork: nil)

        guard let ancestor,
              let values = try? URL(fileURLWithPath: ancestor).resourceValues(forKeys: volumeKeys)
        else { return info }

        info.volumeName  = values.volumeName
        info.volumeUUID  = values.volumeUUIDString
        info.mountPoint  = values.volume?.path
        info.isRemovable = values.volumeIsRemovable
        info.isNetwork   = isNetworkVolume(atPath: ancestor)
        return info
    }

    /// `URLResourceValues` has no network flag on macOS; ask statfs instead.
    private static func isNetworkVolume(atPath path: String) -> Bool? {
        var stat = statfs()
        guard statfs(path, &stat) == 0 else { return nil }
        return (stat.f_flags & UInt32(MNT_LOCAL)) == 0
    }

    // MARK: - Startup report

    /// Logs which database file was opened and where it came from. Written before any
    /// query runs, so a truncated log still shows the path that was in play.
    static func logDatabaseOpen(url: URL, restoredFromDefaults: Bool, defaultURL: URL) {
        let fm = FileManager.default
        log("=== database open ===")
        log("path=\(url.path)")
        log("source=\(restoredFromDefaults ? "UserDefaults[lastDatabasePath]" : "default location")")
        log("defaultPath=\(defaultURL.path)")
        log("db     \(volumeInfo(for: url.path).summary)")

        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        log("size=\(size.map { "\($0) bytes" } ?? "missing")")
        for suffix in ["-wal", "-shm"] {
            let sidecar = url.path + suffix
            if fm.fileExists(atPath: sidecar) {
                let s = (try? fm.attributesOfItem(atPath: sidecar)[.size] as? Int64) ?? nil
                log("sidecar \(suffix) present (\(s.map(String.init) ?? "?") bytes)")
            }
        }
        // Only report a vanished file here. A file that exists but fails to open is
        // reported separately, with the SQLite error, by the caller's fallback path.
        if !restoredFromDefaults,
           let remembered = UserDefaults.standard.string(forKey: "lastDatabasePath"),
           remembered != url.path,
           !fm.fileExists(atPath: remembered) {
            log("NOTE: lastDatabasePath pointed at \(remembered), which no longer exists — "
                + "fell back to the default database.")
        }
    }

    /// Logs every watched folder with its current reachability and volume identity.
    /// This is the line that shows a `-1` suffixed remount at a glance.
    static func logWatchedFolders(_ folders: [WatchedFolder]) {
        log("=== watched folders (\(folders.count)) ===")
        for folder in folders {
            let info = volumeInfo(for: folder.path)
            let scanned = folder.scannedFileCount.map(String.init) ?? "never scanned"
            log("folder \(folder.path)")
            log("       \(info.summary)  storedFileCount=\(scanned)")
            if !info.exists {
                log("       *** MISSING — every file_url under this prefix is unreachable. "
                    + "Relocate the library instead of rescanning. ***")
            }
        }
    }

    /// Compares stored path prefixes against what is currently mounted and names the
    /// most likely replacement, so the relocation sheet can pre-fill a suggestion.
    static func mountedVolumePaths() -> [String] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
        let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                           options: [.skipHiddenVolumes]) ?? []
        return mounts.map(\.path)
    }
}
