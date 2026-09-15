import Testing
import Foundation
import GRDB
@testable import SoundSearch

/// Exercises the path-prefix rewrite against real migrated databases, including the
/// cases that made a naive `LIKE` implementation wrong: paths containing LIKE
/// wildcards, sibling prefixes, and rows a partial rescan already created at the
/// destination.
struct LibraryRelocatorTests {

    // MARK: - Fixtures

    private struct Fixture {
        let dir: URL
        let library: DatabasePool
        let projects: DatabasePool
        let relocator: LibraryRelocator
    }

    private func makeFixture() throws -> Fixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relocator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let library = try DatabasePool.setup(at: dir.appendingPathComponent("library.sqlite"))

        // Mirrors setupProjectsDatabase(), but in the temp directory rather than the
        // real Application Support location.
        let projects = try DatabasePool(path: dir.appendingPathComponent("projects.sqlite").path)
        try projects.write { db in
            try db.create(table: "projects") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "project_files") { t in
                t.column("project_id", .integer).notNull()
                    .references("projects", onDelete: .cascade)
                t.column("file_url", .text).notNull()
                t.column("date_added", .datetime).notNull()
                t.primaryKey(["project_id", "file_url"])
            }
        }

        return Fixture(dir: dir, library: library, projects: projects,
                       relocator: LibraryRelocator(libraryDB: library, projectsDB: projects))
    }

    private func insertFile(_ db: DatabasePool, path: String, rating: Int = 0,
                            description: String = "") throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO audio_files
                  (file_url, filename, file_size, mtime, format, bwf_description,
                   notes, star_rating, date_added, last_modified)
                VALUES (?, ?, 1, 1.0, 'WAV', ?, '', ?, ?, ?)
                """, arguments: [path, (path as NSString).lastPathComponent,
                                 description, rating, Date(), Date()])
        }
    }

    private func urls(_ db: DatabasePool) throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: "SELECT file_url FROM audio_files ORDER BY file_url")
        }
    }

    // MARK: - Tests

    @Test func rewritesPathsWithoutTouchingSiblingPrefixes() throws {
        let f = try makeFixture()
        // "SFX_01" is a live LIKE pattern: "_" matches any character. A LIKE-based
        // implementation drags /Volumes/SFXX01 along with it.
        let newRoot = f.dir.appendingPathComponent("SFX_01-1").path
        try FileManager.default.createDirectory(atPath: newRoot, withIntermediateDirectories: true)

        try insertFile(f.library, path: "/Volumes/SFX_01/Lib/door.wav", rating: 5)
        try insertFile(f.library, path: "/Volumes/SFX_01/Lib/sub/glass.wav", rating: 4)
        try insertFile(f.library, path: "/Volumes/SFXX01/Lib/decoy.wav")
        try insertFile(f.library, path: "/Volumes/SFX_01_OLD/Lib/sibling.wav")

        let result = try f.relocator.relocate(from: "/Volumes/SFX_01", to: newRoot)

        #expect(result.audioFilesUpdated == 2)
        #expect(try urls(f.library) == [
            "/Volumes/SFXX01/Lib/decoy.wav",
            "/Volumes/SFX_01_OLD/Lib/sibling.wav",
            newRoot + "/Lib/door.wav",
            newRoot + "/Lib/sub/glass.wav",
        ].sorted())
    }

    @Test func keepsOriginalRecordWhenDestinationWasPartlyRescanned() throws {
        let f = try makeFixture()
        let newRoot = f.dir.appendingPathComponent("NewDrive").path
        try FileManager.default.createDirectory(atPath: newRoot, withIntermediateDirectories: true)

        try insertFile(f.library, path: "/Volumes/Old/door.wav", rating: 5, description: "wooden door")
        // What a partial rescan on the new machine leaves behind: same file, no rating.
        try insertFile(f.library, path: newRoot + "/door.wav", rating: 0, description: "wooden door")

        let result = try f.relocator.relocate(from: "/Volumes/Old", to: newRoot)

        #expect(result.duplicatesReplaced == 1)
        let rows = try f.library.read { db in
            try Row.fetchAll(db, sql: "SELECT file_url, star_rating FROM audio_files")
        }
        #expect(rows.count == 1)
        #expect(rows[0]["file_url"] == newRoot + "/door.wav")
        // The surviving row must be the one carrying the user's metadata.
        #expect(rows[0]["star_rating"] == 5)
    }

    @Test func leavesNoOrphansInTheFTSIndex() throws {
        let f = try makeFixture()
        let newRoot = f.dir.appendingPathComponent("NewDrive").path
        try FileManager.default.createDirectory(atPath: newRoot, withIntermediateDirectories: true)

        try insertFile(f.library, path: "/Volumes/Old/door.wav", rating: 5, description: "wooden door")
        try insertFile(f.library, path: newRoot + "/door.wav", description: "wooden door")

        try f.relocator.relocate(from: "/Volumes/Old", to: newRoot)

        try f.library.read { db in
            // SQLite only fires delete triggers during REPLACE conflict resolution when
            // recursive_triggers is on. If the duplicate is removed by REPLACE rather
            // than an explicit DELETE, its row survives here forever.
            //
            // Counted through the docsize shadow table: audio_files_fts is an
            // external-content table declaring a tags_denorm column that audio_files
            // does not have, so any unconstrained scan of the view itself fails with
            // "no such column: T.tags_denorm".
            let orphans = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM audio_files_fts_docsize
                WHERE rowid NOT IN (SELECT id FROM audio_files)
                """) ?? 0
            #expect(orphans == 0)

            let hits = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM audio_files
                JOIN audio_files_fts ON audio_files_fts.rowid = audio_files.id
                WHERE audio_files_fts MATCH 'wooden'
                """) ?? 0
            #expect(hits == 1)
        }
    }

    @Test func rewritesWatchedFoldersAndProjectMembership() throws {
        let f = try makeFixture()
        let newRoot = f.dir.appendingPathComponent("NewDrive").path
        try FileManager.default.createDirectory(atPath: newRoot, withIntermediateDirectories: true)

        try f.library.write { db in
            try db.execute(sql: """
                INSERT INTO watched_folders (path, bookmark_data, date_added, scanned_file_count)
                VALUES (?, x'00', ?, 2)
                """, arguments: ["/Volumes/Old", Date()])
        }
        try insertFile(f.library, path: "/Volumes/Old/door.wav")
        try f.projects.write { db in
            try db.execute(sql: "INSERT INTO projects (name, sort_order) VALUES ('P', 0)")
            try db.execute(sql: """
                INSERT INTO project_files (project_id, file_url, date_added) VALUES (1, ?, ?)
                """, arguments: ["/Volumes/Old/door.wav", Date()])
        }

        let result = try f.relocator.relocate(from: "/Volumes/Old", to: newRoot)

        #expect(result.watchedFoldersUpdated == 1)
        #expect(result.projectFilesUpdated == 1)

        let folderPath = try f.library.read { db in
            try String.fetchOne(db, sql: "SELECT path FROM watched_folders")
        }
        #expect(folderPath == newRoot)

        let projectURL = try f.projects.read { db in
            try String.fetchOne(db, sql: "SELECT file_url FROM project_files")
        }
        #expect(projectURL == newRoot + "/door.wav")
    }

    @Test func previewCountsMatchWhatRelocateChanges() throws {
        let f = try makeFixture()
        let newRoot = f.dir.appendingPathComponent("NewDrive").path
        try FileManager.default.createDirectory(atPath: newRoot, withIntermediateDirectories: true)

        try insertFile(f.library, path: "/Volumes/Old/a.wav")
        try insertFile(f.library, path: "/Volumes/Old/b.wav")
        try insertFile(f.library, path: newRoot + "/a.wav")          // conflict
        try insertFile(f.library, path: newRoot + "/only-new.wav")   // not a conflict

        let preview = try f.relocator.preview(from: "/Volumes/Old", to: newRoot)
        #expect(preview.audioFiles == 2)
        #expect(preview.conflictingAudioFiles == 1)

        let result = try f.relocator.relocate(from: "/Volumes/Old", to: newRoot)
        #expect(result.audioFilesUpdated == preview.audioFiles)
        #expect(result.duplicatesReplaced == preview.conflictingAudioFiles)
    }

    @Test func refusesRelocationToAMissingOrIdenticalLocation() throws {
        let f = try makeFixture()
        try insertFile(f.library, path: "/Volumes/Old/a.wav")

        #expect(throws: LibraryRelocator.RelocationError.self) {
            try f.relocator.relocate(from: "/Volumes/Old", to: "/Volumes/Old")
        }
        #expect(throws: LibraryRelocator.RelocationError.self) {
            try f.relocator.relocate(from: "/Volumes/Old", to: "/Volumes/DefinitelyNotMounted-XYZ")
        }
        // Nothing was rewritten by the rejected attempts.
        #expect(try urls(f.library) == ["/Volumes/Old/a.wav"])
    }

    @Test func trailingSlashesAndRelativeSegmentsAreNormalized() throws {
        let f = try makeFixture()
        let newRoot = f.dir.appendingPathComponent("NewDrive").path
        try FileManager.default.createDirectory(atPath: newRoot, withIntermediateDirectories: true)

        try insertFile(f.library, path: "/Volumes/Old/door.wav")

        let result = try f.relocator.relocate(from: "/Volumes/Old/", to: newRoot + "/")
        #expect(result.audioFilesUpdated == 1)
        #expect(try urls(f.library) == [newRoot + "/door.wav"])
    }
}
