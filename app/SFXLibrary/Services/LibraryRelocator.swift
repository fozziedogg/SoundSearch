import Foundation
import GRDB

/// Rewrites stored absolute-path prefixes when a library volume remounts somewhere else
/// or the database is carried to another system.
///
/// Without this, the only recovery is a full rescan: `FolderScanner` keys its skip-cache
/// on `file_url`, so a changed mount point misses on every file and re-ingests the whole
/// library (hours on a large SFX drive). A prefix rewrite is a handful of UPDATEs and
/// preserves ratings, notes, tags, and project membership.
struct LibraryRelocator {
    let libraryDB: DatabasePool
    let projectsDB: DatabasePool

    struct Preview {
        var audioFiles: Int
        var watchedFolders: Int
        var projectFiles: Int
        var conflictingAudioFiles: Int

        var isEmpty: Bool { audioFiles == 0 && watchedFolders == 0 && projectFiles == 0 }
    }

    struct Result {
        var audioFilesUpdated: Int
        var watchedFoldersUpdated: Int
        var projectFilesUpdated: Int
        var duplicatesReplaced: Int
    }

    enum RelocationError: LocalizedError {
        case sameLocation
        case newLocationMissing(String)

        var errorDescription: String? {
            switch self {
            case .sameLocation:
                return "The new location is the same as the old one."
            case .newLocationMissing(let path):
                return "The new location does not exist: \(path)"
            }
        }
    }

    // MARK: - Prefix matching
    //
    // Prefix comparison is done with substr(), never LIKE. Library paths routinely
    // contain "_" and occasionally "%", both of which are LIKE wildcards — `LIKE
    // '/Volumes/SFX_01/%'` would also match `/Volumes/SFXX01/...`. All lengths are
    // measured by SQLite's length() rather than Swift's String.count, because macOS
    // filenames are NFD and a decomposed character counts as one Swift grapheme but
    // several SQLite characters.

    private static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: - Preview

    /// Counts what a relocation would touch, without changing anything.
    func preview(from oldPrefix: String, to newPrefix: String) throws -> Preview {
        let old = Self.normalize(oldPrefix)
        let new = Self.normalize(newPrefix)
        let oldSlash = old + "/"
        let newSlash = new + "/"

        let library = try libraryDB.read { db -> (Int, Int, Int) in
            let files = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM audio_files
                WHERE substr(file_url, 1, length(?)) = ?
                """, arguments: [oldSlash, oldSlash]) ?? 0

            let folders = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM watched_folders
                WHERE path = ? OR substr(path, 1, length(?)) = ?
                """, arguments: [old, oldSlash, oldSlash]) ?? 0

            // Rows already sitting at the destination — a partial rescan on the new
            // machine creates these. They lose to the originals during the rewrite.
            let conflicts = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM audio_files new_rows
                WHERE substr(new_rows.file_url, 1, length(?)) = ?
                  AND EXISTS (
                        SELECT 1 FROM audio_files old_rows
                        WHERE substr(old_rows.file_url, 1, length(?)) = ?
                          AND ? || substr(old_rows.file_url, length(?)) = new_rows.file_url
                  )
                """, arguments: [newSlash, newSlash, oldSlash, oldSlash, new, oldSlash]) ?? 0

            return (files, folders, conflicts)
        }

        let projectFiles = try projectsDB.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM project_files
                WHERE substr(file_url, 1, length(?)) = ?
                """, arguments: [oldSlash, oldSlash]) ?? 0
        }

        return Preview(audioFiles: library.0,
                       watchedFolders: library.1,
                       projectFiles: projectFiles,
                       conflictingAudioFiles: library.2)
    }

    // MARK: - Apply

    /// Rewrites every stored path under `oldPrefix` to sit under `newPrefix`.
    ///
    /// Rows a partial rescan already created at the destination are deleted first, by an
    /// explicit DELETE rather than by letting `UPDATE OR REPLACE` resolve the conflict.
    /// SQLite only fires delete triggers during REPLACE when `recursive_triggers` is on,
    /// which it is not here — a REPLACE would leave the duplicate's row permanently in
    /// the FTS index. The originals survive either way; they are the rows carrying star
    /// ratings, notes, and tag links.
    @discardableResult
    func relocate(from oldPrefix: String, to newPrefix: String) throws -> Result {
        let old = Self.normalize(oldPrefix)
        let new = Self.normalize(newPrefix)
        guard old != new else { throw RelocationError.sameLocation }
        guard FileManager.default.fileExists(atPath: new) else {
            throw RelocationError.newLocationMissing(new)
        }

        let oldSlash = old + "/"
        let newSlash = new + "/"
        let before = try preview(from: old, to: new)

        LibraryDiagnostics.log("=== relocate ===")
        LibraryDiagnostics.log("from=\(old)")
        LibraryDiagnostics.log("to  =\(new)")
        LibraryDiagnostics.log("to   \(LibraryDiagnostics.volumeInfo(for: new).summary)")
        LibraryDiagnostics.log("will rewrite \(before.audioFiles) audio_files, "
            + "\(before.watchedFolders) watched_folders, \(before.projectFiles) project_files "
            + "(\(before.conflictingAudioFiles) duplicate rows at the destination will be dropped)")

        let (files, folders, dupes) = try libraryDB.write { db -> (Int, Int, Int) in
            // Clear the destination first so the plain UPDATEs below cannot hit a UNIQUE
            // violation. This DELETE fires audio_files_ad, which is what keeps the FTS
            // index and the file_tags / file_categories cascades correct.
            try db.execute(sql: """
                DELETE FROM audio_files
                WHERE substr(file_url, 1, length(?)) = ?
                  AND EXISTS (
                        SELECT 1 FROM audio_files old_rows
                        WHERE substr(old_rows.file_url, 1, length(?)) = ?
                          AND ? || substr(old_rows.file_url, length(?)) = audio_files.file_url
                  )
                """, arguments: [newSlash, newSlash, oldSlash, oldSlash, new, oldSlash])
            let duplicatesRemoved = db.changesCount

            try db.execute(sql: """
                UPDATE audio_files
                SET file_url = ? || substr(file_url, length(?))
                WHERE substr(file_url, 1, length(?)) = ?
                """, arguments: [new, oldSlash, oldSlash, oldSlash])
            let filesChanged = db.changesCount

            // watched_folders has no FTS triggers, but the same UNIQUE(path) conflict
            // applies when the folder was re-added at its new location.
            try db.execute(sql: """
                DELETE FROM watched_folders
                WHERE path = ? OR substr(path, 1, length(?)) = ?
                """, arguments: [new, newSlash, newSlash])

            try db.execute(sql: """
                UPDATE watched_folders
                SET path = ? || substr(path, length(?))
                WHERE substr(path, 1, length(?)) = ?
                """, arguments: [new, oldSlash, oldSlash, oldSlash])
            var foldersChanged = db.changesCount

            try db.execute(sql: "UPDATE watched_folders SET path = ? WHERE path = ?",
                           arguments: [new, old])
            foldersChanged += db.changesCount

            return (filesChanged, foldersChanged, duplicatesRemoved)
        }

        let projectFiles = try projectsDB.write { db -> Int in
            try db.execute(sql: """
                DELETE FROM project_files
                WHERE substr(file_url, 1, length(?)) = ?
                  AND EXISTS (
                        SELECT 1 FROM project_files old_rows
                        WHERE old_rows.project_id = project_files.project_id
                          AND substr(old_rows.file_url, 1, length(?)) = ?
                          AND ? || substr(old_rows.file_url, length(?)) = project_files.file_url
                  )
                """, arguments: [newSlash, newSlash, oldSlash, oldSlash, new, oldSlash])

            try db.execute(sql: """
                UPDATE project_files
                SET file_url = ? || substr(file_url, length(?))
                WHERE substr(file_url, 1, length(?)) = ?
                """, arguments: [new, oldSlash, oldSlash, oldSlash])
            return db.changesCount
        }

        // Capture durable identity for everything just moved. This is what turns a manual
        // relocation into a one-time act: from here on VolumeResolver re-derives these
        // paths at every open, so the next remount needs no user action.
        if let location = VolumeIndex.split(path: new) {
            let prefix = VolumeIndex.mountPrefix(location.identity.mountPoint)
            try libraryDB.write { db in
                try db.execute(sql: """
                    UPDATE audio_files
                    SET volume_uuid = ?, volume_relative_path = substr(file_url, length(?) + 1)
                    WHERE substr(file_url, 1, length(?)) = ?
                    """, arguments: [location.identity.key, prefix, prefix, prefix])
                try db.execute(sql: """
                    UPDATE watched_folders
                    SET volume_uuid = ?, volume_relative_path = ?
                    WHERE path = ?
                    """, arguments: [location.identity.key, location.relativePath, new])
            }
            LibraryDiagnostics.log("captured volume identity \(location.identity.key) "
                + "at mount \(location.identity.mountPoint)")
        } else {
            LibraryDiagnostics.log("WARNING: could not determine volume identity for \(new) — "
                + "future remounts of this drive will need relocating again")
        }

        let result = Result(audioFilesUpdated: files,
                            watchedFoldersUpdated: folders,
                            projectFilesUpdated: projectFiles,
                            duplicatesReplaced: dupes)

        LibraryDiagnostics.log("relocate done — audio_files=\(result.audioFilesUpdated) "
            + "watched_folders=\(result.watchedFoldersUpdated) "
            + "project_files=\(result.projectFilesUpdated)")
        return result
    }

    // MARK: - Suggestion

    /// Best guess at where a missing folder went: same volume name mounted elsewhere
    /// (`/Volumes/SFX` → `/Volumes/SFX-1`), or the same trailing path on another mount.
    static func suggestedNewLocation(forMissing oldPath: String) -> String? {
        let old = normalize(oldPath)
        let fm  = FileManager.default

        // /Volumes/<name>/<rest…> — try each mounted volume with the same tail.
        let components = old.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 2, components[1] == "Volumes" else { return nil }
        let originalVolume = components[2]
        let tail = components.dropFirst(3).joined(separator: "/")

        for mount in LibraryDiagnostics.mountedVolumePaths() {
            let mountName = (mount as NSString).lastPathComponent
            // "SFX-1", "SFX 1", "SFX_2" all mean the same drive remounted.
            let stripped = mountName.replacingOccurrences(
                of: "[-_ ]\\d+$", with: "", options: .regularExpression)
            guard stripped == originalVolume || mountName == originalVolume else { continue }
            let candidate = tail.isEmpty ? mount : mount + "/" + tail
            if fm.fileExists(atPath: candidate), candidate != old { return candidate }
        }
        return nil
    }
}
