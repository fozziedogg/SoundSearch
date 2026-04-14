import Foundation
import GRDB

extension DatabasePool {
    /// The directory where the database and its WAL files live.
    static var databaseDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("SFXLibrary_database", isDirectory: true)
    }

    /// The canonical URL of the SQLite database file.
    static var databaseURL: URL {
        databaseDirectory.appendingPathComponent("library.sqlite")
    }

    /// Opens (or creates) a database at an arbitrary URL and runs all migrations.
    static func setup(at url: URL) throws -> DatabasePool {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let pool  = try DatabasePool(path: url.path)

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "audio_files") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("file_url",           .text).notNull().unique()
                t.column("bookmark_data",      .blob)
                t.column("filename",           .text).notNull()
                t.column("file_size",          .integer).notNull()
                t.column("mtime",              .double).notNull()
                t.column("format",             .text).notNull()
                t.column("duration",           .double)
                t.column("sample_rate",        .integer)
                t.column("bit_depth",          .integer)
                t.column("channels",           .integer)
                t.column("lufs",               .double)
                t.column("bwf_description",    .text).defaults(to: "")
                t.column("bwf_originator",     .text).defaults(to: "")
                t.column("bwf_scene",          .text).defaults(to: "")
                t.column("bwf_take",           .text).defaults(to: "")
                t.column("bwf_time_ref_low",   .integer).defaults(to: 0)
                t.column("bwf_time_ref_high",  .integer).defaults(to: 0)
                t.column("ixml_raw",           .text)
                t.column("notes",              .text).defaults(to: "")
                t.column("star_rating",        .integer).defaults(to: 0)
                t.column("waveform_peaks",     .blob)
                t.column("date_added",         .datetime).notNull()
                t.column("last_modified",      .datetime).notNull()
            }

            // Indexes for filter performance on large libraries
            try db.create(index: "idx_af_filename",    on: "audio_files", columns: ["filename"])
            try db.create(index: "idx_af_format",      on: "audio_files", columns: ["format"])
            try db.create(index: "idx_af_sample_rate", on: "audio_files", columns: ["sample_rate"])
            try db.create(index: "idx_af_duration",    on: "audio_files", columns: ["duration"])
            try db.create(index: "idx_af_star_rating", on: "audio_files", columns: ["star_rating"])
            try db.create(index: "idx_af_mtime",       on: "audio_files", columns: ["mtime"])

            try db.create(table: "tags") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name",      .text).notNull().unique().collate(.nocase)
                t.column("color_hex", .text)
            }

            try db.create(table: "file_tags") { t in
                t.column("file_id", .integer).notNull()
                    .references("audio_files", onDelete: .cascade)
                t.column("tag_id",  .integer).notNull()
                    .references("tags", onDelete: .cascade)
                t.primaryKey(["file_id", "tag_id"])
            }

            try db.create(table: "categories") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name",       .text).notNull()
                t.column("parent_id",  .integer).references("categories", onDelete: .setNull)
                t.column("sort_order", .integer).defaults(to: 0)
            }

            try db.create(table: "file_categories") { t in
                t.column("file_id",     .integer).notNull()
                    .references("audio_files", onDelete: .cascade)
                t.column("category_id", .integer).notNull()
                    .references("categories", onDelete: .cascade)
                t.primaryKey(["file_id", "category_id"])
            }

            try db.create(table: "watched_folders") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path",          .text).notNull().unique()
                t.column("bookmark_data", .blob).notNull()
                t.column("date_added",    .datetime).notNull()
                t.column("last_scanned",  .datetime)
            }

            // FTS5 full-text search table
            try db.execute(sql: """
                CREATE VIRTUAL TABLE audio_files_fts USING fts5(
                    filename, bwf_description, bwf_originator, bwf_scene, bwf_take,
                    notes, tags_denorm,
                    content='audio_files',
                    content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2'
                )
            """)

            // Triggers to keep FTS in sync with audio_files
            try db.execute(sql: """
                CREATE TRIGGER audio_files_ai AFTER INSERT ON audio_files BEGIN
                    INSERT INTO audio_files_fts(rowid, filename, bwf_description,
                        bwf_originator, bwf_scene, bwf_take, notes, tags_denorm)
                    VALUES (new.id, new.filename, new.bwf_description,
                        new.bwf_originator, new.bwf_scene, new.bwf_take, new.notes, '');
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER audio_files_ad AFTER DELETE ON audio_files BEGIN
                    INSERT INTO audio_files_fts(audio_files_fts, rowid, filename,
                        bwf_description, bwf_originator, bwf_scene, bwf_take, notes, tags_denorm)
                    VALUES ('delete', old.id, old.filename, old.bwf_description,
                        old.bwf_originator, old.bwf_scene, old.bwf_take, old.notes, '');
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER audio_files_au AFTER UPDATE ON audio_files BEGIN
                    INSERT INTO audio_files_fts(audio_files_fts, rowid, filename,
                        bwf_description, bwf_originator, bwf_scene, bwf_take, notes, tags_denorm)
                    VALUES ('delete', old.id, old.filename, old.bwf_description,
                        old.bwf_originator, old.bwf_scene, old.bwf_take, old.notes, '');
                    INSERT INTO audio_files_fts(rowid, filename, bwf_description,
                        bwf_originator, bwf_scene, bwf_take, notes, tags_denorm)
                    VALUES (new.id, new.filename, new.bwf_description,
                        new.bwf_originator, new.bwf_scene, new.bwf_take, new.notes, '');
                END
            """)
        }

        migrator.registerMigration("v2_extended_metadata") { db in
            try db.alter(table: "audio_files") { t in
                t.add(column: "origination_date", .text).defaults(to: "")
                t.add(column: "tape_name",        .text).defaults(to: "")
                t.add(column: "ixml_note",        .text).defaults(to: "")
                t.add(column: "ucs_category",     .text).defaults(to: "")
                t.add(column: "ucs_sub_category", .text).defaults(to: "")
            }

            // Rebuild FTS to include new searchable fields.
            // Drop old triggers first, then the virtual table, then recreate both.
            try db.execute(sql: "DROP TRIGGER IF EXISTS audio_files_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS audio_files_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS audio_files_au")
            try db.execute(sql: "DROP TABLE IF EXISTS audio_files_fts")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE audio_files_fts USING fts5(
                    filename, bwf_description, bwf_originator, bwf_scene, bwf_take,
                    notes, tape_name, ixml_note, ucs_category, ucs_sub_category, tags_denorm,
                    content='audio_files',
                    content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2'
                )
            """)

            // Repopulate from existing rows
            try db.execute(sql: """
                INSERT INTO audio_files_fts(
                    rowid, filename, bwf_description, bwf_originator, bwf_scene, bwf_take,
                    notes, tape_name, ixml_note, ucs_category, ucs_sub_category, tags_denorm)
                SELECT
                    id, filename, bwf_description, bwf_originator, bwf_scene, bwf_take,
                    notes, tape_name, ixml_note, ucs_category, ucs_sub_category, ''
                FROM audio_files
            """)

            let triggerCols = """
                filename, bwf_description, bwf_originator, bwf_scene, bwf_take,
                notes, tape_name, ixml_note, ucs_category, ucs_sub_category, tags_denorm
            """
            try db.execute(sql: """
                CREATE TRIGGER audio_files_ai AFTER INSERT ON audio_files BEGIN
                    INSERT INTO audio_files_fts(rowid, \(triggerCols))
                    VALUES (new.id, new.filename, new.bwf_description,
                        new.bwf_originator, new.bwf_scene, new.bwf_take, new.notes,
                        new.tape_name, new.ixml_note, new.ucs_category, new.ucs_sub_category, '');
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER audio_files_ad AFTER DELETE ON audio_files BEGIN
                    INSERT INTO audio_files_fts(audio_files_fts, rowid, \(triggerCols))
                    VALUES ('delete', old.id, old.filename, old.bwf_description,
                        old.bwf_originator, old.bwf_scene, old.bwf_take, old.notes,
                        old.tape_name, old.ixml_note, old.ucs_category, old.ucs_sub_category, '');
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER audio_files_au AFTER UPDATE ON audio_files BEGIN
                    INSERT INTO audio_files_fts(audio_files_fts, rowid, \(triggerCols))
                    VALUES ('delete', old.id, old.filename, old.bwf_description,
                        old.bwf_originator, old.bwf_scene, old.bwf_take, old.notes,
                        old.tape_name, old.ixml_note, old.ucs_category, old.ucs_sub_category, '');
                    INSERT INTO audio_files_fts(rowid, \(triggerCols))
                    VALUES (new.id, new.filename, new.bwf_description,
                        new.bwf_originator, new.bwf_scene, new.bwf_take, new.notes,
                        new.tape_name, new.ixml_note, new.ucs_category, new.ucs_sub_category, '');
                END
            """)
        }

        migrator.registerMigration("v3_drop_blob_columns") { db in
            // waveform_peaks: ThumbnailCache is memory-only; column was never read back.
            // ixml_raw: individual iXML fields are stored in separate columns; raw XML not needed.
            try db.execute(sql: "ALTER TABLE audio_files DROP COLUMN ixml_raw")
            try db.execute(sql: "ALTER TABLE audio_files DROP COLUMN waveform_peaks")
        }

        try migrator.migrate(pool)
        return pool
    }

    /// Convenience: opens the default library database in ~/Documents/SFXLibrary_database/.
    static func setupShared() throws -> DatabasePool {
        try setup(at: databaseURL)
    }
}
