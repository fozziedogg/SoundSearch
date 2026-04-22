import Foundation
import GRDB

final class AudioFileRepository {
    private let db: DatabasePool

    init(db: DatabasePool) {
        self.db = db
    }

    func upsert(_ file: inout AudioFile) throws {
        try db.write { db in
            try file.upsert(db)
        }
    }

    func delete(fileURL: String) throws {
        try db.write { db in
            try AudioFile.filter(AudioFile.Columns.fileURL == fileURL).deleteAll(db)
        }
    }

    func fetchAll(limit: Int = 200, offset: Int = 0) throws -> [AudioFile] {
        try db.read { db in
            try AudioFile
                .order(AudioFile.Columns.filename)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func fetch(fileURL: String) throws -> AudioFile? {
        try db.read { db in
            try AudioFile.filter(AudioFile.Columns.fileURL == fileURL).fetchOne(db)
        }
    }

    /// Returns a dictionary of [filePath: mtime] for all indexed files.
    /// Used by FolderScanner to skip unchanged files without per-file queries.
    func fetchAllMtimes() throws -> [String: Double] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT file_url, mtime FROM audio_files")
            var result = [String: Double](minimumCapacity: rows.count)
            for row in rows {
                result[row["file_url"]] = row["mtime"]
            }
            return result
        }
    }

    func updateMetadata(_ file: AudioFile) throws {
        try db.write { db in
            try file.update(db)
        }
    }
}
