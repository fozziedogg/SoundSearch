import Testing
import Foundation
import GRDB
@testable import SoundSearch

/// Drives the resolver with synthetic volumes so the remount scenarios can be tested
/// without attaching real drives: a drive that comes back at a different mount point, a
/// database carried to a machine that mounts it elsewhere, and a drive that is simply
/// absent. A real disk image exercises the macOS side separately.
struct VolumeResolverTests {

    private struct Fixture {
        let dir: URL
        let library: DatabasePool
        let projects: DatabasePool
    }

    private func makeFixture() throws -> Fixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let library = try DatabasePool.setup(at: dir.appendingPathComponent("library.sqlite"))
        let projects = try DatabasePool(path: dir.appendingPathComponent("projects.sqlite").path)
        try projects.write { db in
            try db.create(table: "projects") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "project_files") { t in
                t.column("project_id", .integer).notNull()
                t.column("file_url", .text).notNull()
                t.column("date_added", .datetime).notNull()
                t.primaryKey(["project_id", "file_url"])
            }
        }
        return Fixture(dir: dir, library: library, projects: projects)
    }

    /// A resolver whose view of the world is entirely synthetic: `mounts` says where each
    /// volume is now, `identifyAs` says which volume a stored path belonged to.
    private func resolver(_ f: Fixture,
                          mounts: [String: String],
                          identifyAs identities: [String: (String, String)]) -> VolumeResolver {
        VolumeResolver(
            libraryDB: f.library,
            projectsDB: f.projects,
            identify: { path in
                // Longest matching stored-mount prefix wins.
                let match = identities
                    .filter { path == $0.value.1 || path.hasPrefix($0.value.1 + "/") }
                    .max { $0.value.1.count < $1.value.1.count }
                guard let match else { return nil }
                let (key, mount) = match.value
                guard let rel = VolumeIndex.relativePath(of: path, underMount: mount) else {
                    return nil
                }
                return (VolumeIndex.Identity(key: key, mountPoint: mount), rel)
            },
            mountsProvider: { mounts })
    }

    private func insertFile(_ db: DatabasePool, path: String, rating: Int = 0,
                            uuid: String? = nil, relative: String? = nil) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO audio_files
                  (file_url, filename, file_size, mtime, format, bwf_description, notes,
                   star_rating, date_added, last_modified, volume_uuid, volume_relative_path)
                VALUES (?, ?, 1, 1.0, 'WAV', '', '', ?, ?, ?, ?, ?)
                """, arguments: [path, (path as NSString).lastPathComponent, rating,
                                 Date(), Date(), uuid, relative])
        }
    }

    private func insertFolder(_ db: DatabasePool, path: String,
                              uuid: String? = nil, relative: String? = nil) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO watched_folders
                  (path, bookmark_data, date_added, scanned_file_count,
                   volume_uuid, volume_relative_path)
                VALUES (?, x'00', ?, 2, ?, ?)
                """, arguments: [path, Date(), uuid, relative])
        }
    }

    private func urls(_ db: DatabasePool) throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: "SELECT file_url FROM audio_files ORDER BY file_url")
        }
    }

    // MARK: - Backfill

    @Test func backfillsDurableIdentityFromCurrentPaths() throws {
        let f = try makeFixture()
        try insertFolder(f.library, path: "/Volumes/SFX")
        try insertFile(f.library, path: "/Volumes/SFX/Lib/door.wav")
        try insertFile(f.library, path: "/Volumes/SFX/Lib/sub/glass.wav")

        let outcome = resolver(f, mounts: ["uuid:ABC": "/Volumes/SFX"],
                               identifyAs: ["v": ("uuid:ABC", "/Volumes/SFX")]).run()

        #expect(outcome.backfilledFolders == 1)
        #expect(outcome.backfilledFiles == 2)

        let rows = try f.library.read { db in
            try Row.fetchAll(db, sql: """
                SELECT volume_uuid, volume_relative_path FROM audio_files ORDER BY file_url
                """)
        }
        #expect(rows.map { $0["volume_uuid"] as String? } == ["uuid:ABC", "uuid:ABC"])
        #expect(rows.map { $0["volume_relative_path"] as String? }
                == ["Lib/door.wav", "Lib/sub/glass.wav"])
    }

    @Test func backfillsFilesWithNoWatchedFolderRow() throws {
        let f = try makeFixture()
        // No watched_folders row at all — the folder was removed but the files remain.
        try insertFile(f.library, path: "/Volumes/SFX/Lib/orphan.wav")

        let outcome = resolver(f, mounts: ["uuid:ABC": "/Volumes/SFX"],
                               identifyAs: ["v": ("uuid:ABC", "/Volumes/SFX")]).run()

        #expect(outcome.backfilledFiles == 1)
        let uuid = try f.library.read { db in
            try String.fetchOne(db, sql: "SELECT volume_uuid FROM audio_files")
        }
        #expect(uuid == "uuid:ABC")
    }

    // MARK: - Repoint

    @Test func repointsPathsWhenTheDriveComesBackElsewhere() throws {
        let f = try makeFixture()
        try insertFolder(f.library, path: "/Volumes/SFX",
                         uuid: "uuid:ABC", relative: "")
        try insertFile(f.library, path: "/Volumes/SFX/Lib/door.wav", rating: 5,
                       uuid: "uuid:ABC", relative: "Lib/door.wav")
        try insertFile(f.library, path: "/Volumes/SFX/Lib/glass.wav",
                       uuid: "uuid:ABC", relative: "Lib/glass.wav")

        // Same drive, now mounted with a collision suffix.
        let outcome = resolver(f, mounts: ["uuid:ABC": "/Volumes/SFX-1"],
                               identifyAs: ["v": ("uuid:ABC", "/Volumes/SFX-1")]).run()

        #expect(outcome.repointedFiles == 2)
        #expect(outcome.repointedFolders == 1)
        #expect(try urls(f.library) == ["/Volumes/SFX-1/Lib/door.wav",
                                        "/Volumes/SFX-1/Lib/glass.wav"])

        let folder = try f.library.read { db in
            try String.fetchOne(db, sql: "SELECT path FROM watched_folders")
        }
        #expect(folder == "/Volumes/SFX-1")

        // Metadata rides along — this is the whole point of not re-indexing.
        let rating = try f.library.read { db in
            try Int.fetchOne(db, sql: """
                SELECT star_rating FROM audio_files WHERE file_url = '/Volumes/SFX-1/Lib/door.wav'
                """)
        }
        #expect(rating == 5)
    }

    @Test func repointsProjectMembershipAlongsideTheFolder() throws {
        let f = try makeFixture()
        try insertFolder(f.library, path: "/Volumes/SFX", uuid: "uuid:ABC", relative: "")
        try insertFile(f.library, path: "/Volumes/SFX/door.wav",
                       uuid: "uuid:ABC", relative: "door.wav")
        try f.projects.write { db in
            try db.execute(sql: "INSERT INTO projects (name, sort_order) VALUES ('P', 0)")
            try db.execute(sql: """
                INSERT INTO project_files (project_id, file_url, date_added) VALUES (1, ?, ?)
                """, arguments: ["/Volumes/SFX/door.wav", Date()])
        }

        let outcome = resolver(f, mounts: ["uuid:ABC": "/Volumes/SFX-1"],
                               identifyAs: ["v": ("uuid:ABC", "/Volumes/SFX-1")]).run()

        #expect(outcome.repointedProjectFiles == 1)
        let url = try f.projects.read { db in
            try String.fetchOne(db, sql: "SELECT file_url FROM project_files")
        }
        #expect(url == "/Volumes/SFX-1/door.wav")
    }

    @Test func isANoOpWhenTheMountPointIsUnchanged() throws {
        let f = try makeFixture()
        try insertFolder(f.library, path: "/Volumes/SFX", uuid: "uuid:ABC", relative: "")
        try insertFile(f.library, path: "/Volumes/SFX/door.wav",
                       uuid: "uuid:ABC", relative: "door.wav")

        let outcome = resolver(f, mounts: ["uuid:ABC": "/Volumes/SFX"],
                               identifyAs: ["v": ("uuid:ABC", "/Volumes/SFX")]).run()

        #expect(outcome.repointedFiles == 0)
        #expect(outcome.repointedFolders == 0)
        #expect(outcome.changedAnything == false)
        #expect(try urls(f.library) == ["/Volumes/SFX/door.wav"])
    }

    @Test func leavesRowsAloneWhenTheVolumeIsNotMounted() throws {
        let f = try makeFixture()
        try insertFolder(f.library, path: "/Volumes/SFX", uuid: "uuid:ABC", relative: "")
        try insertFile(f.library, path: "/Volumes/SFX/door.wav", rating: 4,
                       uuid: "uuid:ABC", relative: "door.wav")

        // Drive is not attached: nothing to repoint against, and nothing may be deleted.
        let outcome = resolver(f, mounts: [:], identifyAs: [:]).run()

        #expect(outcome.unmountedVolumes == ["uuid:ABC"])
        #expect(outcome.repointedFiles == 0)
        #expect(try urls(f.library) == ["/Volumes/SFX/door.wav"])
        let rating = try f.library.read { db in
            try Int.fetchOne(db, sql: "SELECT star_rating FROM audio_files")
        }
        #expect(rating == 4)
    }

    @Test func dropsRowsAPartialRescanLeftAtTheNewMountPoint() throws {
        let f = try makeFixture()
        try insertFolder(f.library, path: "/Volumes/SFX", uuid: "uuid:ABC", relative: "")
        try insertFile(f.library, path: "/Volumes/SFX/door.wav", rating: 5,
                       uuid: "uuid:ABC", relative: "door.wav")
        // What a rescan under the new mount point created before the resolver ran.
        try insertFile(f.library, path: "/Volumes/SFX-1/door.wav", rating: 0)

        let outcome = resolver(f, mounts: ["uuid:ABC": "/Volumes/SFX-1"],
                               identifyAs: ["v": ("uuid:ABC", "/Volumes/SFX-1")]).run()

        #expect(outcome.duplicatesRemoved == 1)
        #expect(try urls(f.library) == ["/Volumes/SFX-1/door.wav"])
        let rating = try f.library.read { db in
            try Int.fetchOne(db, sql: "SELECT star_rating FROM audio_files")
        }
        #expect(rating == 5)   // the original row won, not the freshly scanned one

        try f.library.read { db in
            let orphans = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM audio_files_fts_docsize
                WHERE rowid NOT IN (SELECT id FROM audio_files)
                """) ?? 0
            #expect(orphans == 0)
        }
    }

    @Test func keepsVolumesApartWhenTwoDrivesAreMounted() throws {
        let f = try makeFixture()
        try insertFolder(f.library, path: "/Volumes/SFX", uuid: "uuid:ABC", relative: "")
        try insertFolder(f.library, path: "/Volumes/Music", uuid: "uuid:DEF", relative: "")
        try insertFile(f.library, path: "/Volumes/SFX/a.wav",
                       uuid: "uuid:ABC", relative: "a.wav")
        try insertFile(f.library, path: "/Volumes/Music/b.wav",
                       uuid: "uuid:DEF", relative: "b.wav")

        // Only the first drive moved.
        _ = resolver(f, mounts: ["uuid:ABC": "/Volumes/SFX-1", "uuid:DEF": "/Volumes/Music"],
                     identifyAs: ["a": ("uuid:ABC", "/Volumes/SFX-1"),
                                  "b": ("uuid:DEF", "/Volumes/Music")]).run()

        #expect(try urls(f.library) == ["/Volumes/Music/b.wav", "/Volumes/SFX-1/a.wav"])
    }

    // MARK: - VolumeIndex path arithmetic

    @Test func relativeAndAbsolutePathsRoundTrip() {
        #expect(VolumeIndex.relativePath(of: "/Volumes/SFX/a/b.wav", underMount: "/Volumes/SFX")
                == "a/b.wav")
        #expect(VolumeIndex.relativePath(of: "/Volumes/SFX", underMount: "/Volumes/SFX") == "")
        #expect(VolumeIndex.relativePath(of: "/Users/nick/a.wav", underMount: "/") == "Users/nick/a.wav")
        // A sibling volume whose name merely starts the same must not match.
        #expect(VolumeIndex.relativePath(of: "/Volumes/SFX2/a.wav", underMount: "/Volumes/SFX") == nil)

        #expect(VolumeIndex.absolutePath(mount: "/Volumes/SFX", relativePath: "a/b.wav")
                == "/Volumes/SFX/a/b.wav")
        #expect(VolumeIndex.absolutePath(mount: "/", relativePath: "Users/nick/a.wav")
                == "/Users/nick/a.wav")
        #expect(VolumeIndex.absolutePath(mount: "/Volumes/SFX", relativePath: "") == "/Volumes/SFX")
    }

    @Test func mountCollisionSuffixesResolveToTheSameName() {
        #expect(VolumeIndex.strippingMountSuffix("SFX-1") == "SFX")
        #expect(VolumeIndex.strippingMountSuffix("SFX 2") == "SFX")
        #expect(VolumeIndex.strippingMountSuffix("SFX_3") == "SFX")
        #expect(VolumeIndex.strippingMountSuffix("SFX") == "SFX")
        // A name that legitimately ends in a number keeps it — only a separator strips.
        #expect(VolumeIndex.strippingMountSuffix("SFX01") == "SFX01")
    }

    /// Newly ingested files must carry identity from the start, otherwise a library built
    /// after v6 would still depend on the backfill pass to become portable.
    @Test func ingestStoresVolumeIdentityForNewFiles() async throws {
        let f = try makeFixture()
        let wav = f.dir.appendingPathComponent("tone.wav")
        // Minimal RIFF/WAVE header — enough for the metadata reader to complete.
        var data = Data("RIFF".utf8)
        data.append(contentsOf: [36, 0, 0, 0])
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0, 0x44, 0xAC, 0, 0,
                                 0x88, 0x58, 1, 0, 2, 0, 16, 0])
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: [0, 0, 0, 0])
        try data.write(to: wav)

        try await LibraryService(db: f.library).ingestFile(at: wav)

        // In an async context `read` resolves to the async overload, hence the await.
        let fetched: Row? = try await f.library.read { db in
            try Row.fetchOne(db, sql: """
                SELECT volume_uuid, volume_relative_path FROM audio_files
                """)
        }
        let row = try #require(fetched)
        let uuid = try #require(row["volume_uuid"] as String?)
        let relative = try #require(row["volume_relative_path"] as String?)
        #expect(uuid.hasPrefix("uuid:"))
        // Temp dirs live on the boot volume, mounted at "/", so the relative path has no
        // leading slash and recomposes to the original absolute path.
        #expect(!relative.hasPrefix("/"))
        let mount = try #require(VolumeIndex.currentMounts()[uuid])
        #expect(VolumeIndex.absolutePath(mount: mount, relativePath: relative) == wav.path)
    }

    /// The boot volume must report a real UUID; if this fails, identity capture would
    /// silently fall back to name matching everywhere.
    @Test func realBootVolumeReportsAUUIDIdentity() throws {
        let identity = try #require(VolumeIndex.identity(forPath: NSTemporaryDirectory()))
        #expect(identity.isUUIDBased)
        #expect(VolumeIndex.currentMounts()[identity.key] == identity.mountPoint)
    }
}
