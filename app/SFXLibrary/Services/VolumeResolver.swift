import Foundation
import GRDB

/// Keeps stored absolute paths in step with where volumes are actually mounted.
///
/// Runs on every database open. Two passes:
///
/// 1. **Backfill** — rows written before v6 (or while their volume was unmounted) get
///    their `(volume_uuid, volume_relative_path)` pair derived from the path they
///    currently hold, while that path is still valid.
/// 2. **Resolve** — for every volume that is mounted right now, regenerate `file_url`
///    from the durable pair. A drive that came back at `/Volumes/SFX-1` instead of
///    `/Volumes/SFX` is corrected here, silently, before the UI reads a single row.
///
/// The manual relocation sheet still exists for the case this cannot cover: the very
/// first move of a pre-v6 database to another machine, where no row has a durable
/// identity and the stored paths describe a machine that isn't this one. After one
/// relocation the pair is captured and later remounts need no user action.
struct VolumeResolver {
    let libraryDB: DatabasePool
    let projectsDB: DatabasePool

    /// Volume lookups are injectable so the resolution logic can be tested against
    /// synthetic drives instead of requiring real mounts.
    var identify: (String) -> (identity: VolumeIndex.Identity, relativePath: String)? = {
        VolumeIndex.split(path: $0)
    }
    var mountsProvider: () -> [String: String] = { VolumeIndex.currentMounts() }

    struct Outcome {
        var backfilledFiles = 0
        var backfilledFolders = 0
        var repointedFiles = 0
        var repointedFolders = 0
        var repointedProjectFiles = 0
        var duplicatesRemoved = 0
        var unmountedVolumes: [String] = []

        var changedAnything: Bool {
            repointedFiles > 0 || repointedFolders > 0 || repointedProjectFiles > 0
        }
    }

    @discardableResult
    func run() -> Outcome {
        var outcome = Outcome()
        let mounts = mountsProvider()
        LibraryDiagnostics.log("=== volume resolve ===")
        LibraryDiagnostics.log("mounted volumes: \(mounts.count)")
        for (key, mount) in mounts.sorted(by: { $0.key < $1.key }) {
            LibraryDiagnostics.log("  \(key) -> \(mount)")
        }

        do {
            try backfill(&outcome)
            try repoint(mounts: mounts, &outcome)
        } catch {
            LibraryDiagnostics.log("volume resolve failed — \(error)")
            return outcome
        }

        if outcome.backfilledFiles > 0 || outcome.backfilledFolders > 0 {
            LibraryDiagnostics.log("backfilled identity for \(outcome.backfilledFiles) file(s), "
                + "\(outcome.backfilledFolders) folder(s)")
        }
        if outcome.changedAnything {
            LibraryDiagnostics.log("repointed \(outcome.repointedFiles) file(s), "
                + "\(outcome.repointedFolders) folder(s), "
                + "\(outcome.repointedProjectFiles) project entr(ies) to current mount points"
                + (outcome.duplicatesRemoved > 0
                   ? "; removed \(outcome.duplicatesRemoved) duplicate row(s)" : ""))
        }
        if !outcome.unmountedVolumes.isEmpty {
            LibraryDiagnostics.log("volumes referenced by the library but not mounted: "
                + outcome.unmountedVolumes.joined(separator: ", "))
        }
        return outcome
    }

    // MARK: - Pass 1: backfill

    /// Derives the durable pair for rows that lack one, using the path they hold today.
    /// Grouped by watched folder, so this costs one volume lookup per folder rather than
    /// one per file — the difference between milliseconds and a stat() storm on 100k rows.
    private func backfill(_ outcome: inout Outcome) throws {
        let folders = try libraryDB.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, path, volume_uuid FROM watched_folders
                """)
        }

        for row in folders {
            let path: String = row["path"]
            guard let split = identify(path) else { continue }
            let prefix = VolumeIndex.mountPrefix(split.identity.mountPoint)

            try libraryDB.write { db in
                if (row["volume_uuid"] as String?) == nil {
                    try db.execute(sql: """
                        UPDATE watched_folders
                        SET volume_uuid = ?, volume_relative_path = ?
                        WHERE id = ?
                        """, arguments: [split.identity.key, split.relativePath, row["id"] as Int64])
                    outcome.backfilledFolders += db.changesCount
                }

                // Every indexed file sitting under this folder's mount belongs to the same
                // volume, so the relative path is pure string arithmetic from here.
                // The NOT EXISTS guard matters when the drive has already been remounted
                // and partly rescanned: those new rows sit at the *current* mount and
                // would be stamped with the same (uuid, relative path) as the originals.
                // Granting them identity makes them indistinguishable from the rows
                // carrying the user's metadata. Left NULL, they are recognised as
                // duplicates and dropped during the repoint pass instead.
                try db.execute(sql: """
                    UPDATE audio_files
                    SET volume_uuid = ?, volume_relative_path = substr(file_url, length(?) + 1)
                    WHERE volume_uuid IS NULL
                      AND substr(file_url, 1, length(?)) = ?
                      AND NOT EXISTS (
                            SELECT 1 FROM audio_files other
                            WHERE other.volume_uuid = ?
                              AND other.volume_relative_path = substr(audio_files.file_url, length(?) + 1)
                      )
                    """, arguments: [split.identity.key, prefix, prefix, prefix,
                                     split.identity.key, prefix])
                outcome.backfilledFiles += db.changesCount
            }
        }

        try backfillStrays(&outcome)
    }

    /// Files can outlive the watched folder that indexed them, and a library can hold rows
    /// from a drive with no folder row at all. Those are covered by deriving candidate
    /// mount roots straight from the remaining paths: `/Volumes/<name>` where that
    /// applies, otherwise the root volume.
    private func backfillStrays(_ outcome: inout Outcome) throws {
        let stray = try libraryDB.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT file_url FROM audio_files WHERE volume_uuid IS NULL LIMIT 5000
                """)
        }
        guard !stray.isEmpty else { return }

        var roots = Set<String>()
        for path in stray {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.count > 2, parts[1] == "Volumes" {
                roots.insert("/Volumes/\(parts[2])")
            } else {
                roots.insert("/")
            }
        }

        for root in roots {
            guard let split = identify(root), split.relativePath.isEmpty else { continue }
            let prefix = VolumeIndex.mountPrefix(split.identity.mountPoint)
            try libraryDB.write { db in
                // The NOT EXISTS guard matters when the drive has already been remounted
                // and partly rescanned: those new rows sit at the *current* mount and
                // would be stamped with the same (uuid, relative path) as the originals.
                // Granting them identity makes them indistinguishable from the rows
                // carrying the user's metadata. Left NULL, they are recognised as
                // duplicates and dropped during the repoint pass instead.
                try db.execute(sql: """
                    UPDATE audio_files
                    SET volume_uuid = ?, volume_relative_path = substr(file_url, length(?) + 1)
                    WHERE volume_uuid IS NULL
                      AND substr(file_url, 1, length(?)) = ?
                      AND NOT EXISTS (
                            SELECT 1 FROM audio_files other
                            WHERE other.volume_uuid = ?
                              AND other.volume_relative_path = substr(audio_files.file_url, length(?) + 1)
                      )
                    """, arguments: [split.identity.key, prefix, prefix, prefix,
                                     split.identity.key, prefix])
                outcome.backfilledFiles += db.changesCount
            }
        }
    }

    // MARK: - Pass 2: repoint

    private func repoint(mounts: [String: String], _ outcome: inout Outcome) throws {
        let keys = try libraryDB.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT volume_uuid FROM audio_files WHERE volume_uuid IS NOT NULL
                UNION
                SELECT DISTINCT volume_uuid FROM watched_folders WHERE volume_uuid IS NOT NULL
                """)
        }

        for key in keys {
            guard let mount = mounts[key] else {
                outcome.unmountedVolumes.append(key)
                continue
            }
            let prefix = VolumeIndex.mountPrefix(mount)

            try libraryDB.write { db in
                // Two rows on the same volume claiming the same relative path would make
                // the UPDATE below violate UNIQUE(file_url) and abort the entire pass,
                // leaving every path stale. Collapse them first, keeping the lowest id:
                // the older row, which is the one that accumulated ratings and notes.
                try db.execute(sql: """
                    DELETE FROM audio_files WHERE id IN (
                        SELECT dup.id FROM audio_files dup
                        WHERE dup.volume_uuid = ?
                          AND dup.volume_relative_path IS NOT NULL
                          AND dup.id > (
                                SELECT MIN(keep.id) FROM audio_files keep
                                WHERE keep.volume_uuid = dup.volume_uuid
                                  AND keep.volume_relative_path = dup.volume_relative_path
                          )
                    )
                    """, arguments: [key])
                outcome.duplicatesRemoved += db.changesCount

                // Clear anything already occupying a target path — a rescan on the new
                // machine may have created rows there. Explicit DELETE rather than
                // UPDATE OR REPLACE: REPLACE skips delete triggers unless
                // recursive_triggers is on, which would strand rows in the FTS index.
                try db.execute(sql: """
                    DELETE FROM audio_files
                    WHERE (volume_uuid IS NULL OR volume_uuid <> ?)
                      AND EXISTS (
                            SELECT 1 FROM audio_files src
                            WHERE src.volume_uuid = ?
                              AND ? || src.volume_relative_path = audio_files.file_url
                      )
                    """, arguments: [key, key, prefix])
                outcome.duplicatesRemoved += db.changesCount

                try db.execute(sql: """
                    UPDATE audio_files
                    SET file_url = ? || volume_relative_path
                    WHERE volume_uuid = ?
                      AND volume_relative_path IS NOT NULL
                      AND file_url <> ? || volume_relative_path
                    """, arguments: [prefix, key, prefix])
                outcome.repointedFiles += db.changesCount
            }

            // Watched folders are few and their relative path may be empty (the folder is
            // the mount root), which the SQL concatenation above cannot express.
            let folders = try libraryDB.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, path, volume_relative_path FROM watched_folders
                    WHERE volume_uuid = ? AND volume_relative_path IS NOT NULL
                    """, arguments: [key])
            }
            for row in folders {
                let relative: String = row["volume_relative_path"]
                let expected = VolumeIndex.absolutePath(mount: mount, relativePath: relative)
                guard expected != (row["path"] as String) else { continue }
                let oldPath: String = row["path"]
                try libraryDB.write { db in
                    try db.execute(sql: "DELETE FROM watched_folders WHERE path = ? AND id <> ?",
                                   arguments: [expected, row["id"] as Int64])
                    try db.execute(sql: "UPDATE watched_folders SET path = ? WHERE id = ?",
                                   arguments: [expected, row["id"] as Int64])
                    outcome.repointedFolders += db.changesCount
                }
                LibraryDiagnostics.log("folder repointed: \(oldPath) -> \(expected)")

                // Project membership lives in its own database with no volume columns, so
                // it is corrected by the same prefix rewrite the relocation sheet uses.
                outcome.repointedProjectFiles += try repointProjectFiles(from: oldPath, to: expected)
            }
        }
    }

    private func repointProjectFiles(from oldPath: String, to newPath: String) throws -> Int {
        let oldPrefix = VolumeIndex.mountPrefix(oldPath)
        let newRoot = newPath.hasSuffix("/") ? String(newPath.dropLast()) : newPath
        return try projectsDB.write { db in
            try db.execute(sql: """
                DELETE FROM project_files
                WHERE substr(file_url, 1, length(?)) = ?
                  AND EXISTS (
                        SELECT 1 FROM project_files src
                        WHERE src.project_id = project_files.project_id
                          AND substr(src.file_url, 1, length(?)) = ?
                          AND ? || substr(src.file_url, length(?)) = project_files.file_url
                  )
                """, arguments: [VolumeIndex.mountPrefix(newRoot), VolumeIndex.mountPrefix(newRoot),
                                 oldPrefix, oldPrefix, newRoot, oldPrefix])
            try db.execute(sql: """
                UPDATE project_files
                SET file_url = ? || substr(file_url, length(?))
                WHERE substr(file_url, 1, length(?)) = ?
                """, arguments: [newRoot, oldPrefix, oldPrefix, oldPrefix])
            return db.changesCount
        }
    }
}
