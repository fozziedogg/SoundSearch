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

    func updateMetadata(_ file: AudioFile) throws {
        try db.write { db in
            try file.update(db)
        }
    }
}
