import Foundation
import GRDB

final class TagRepository {
    private let db: DatabasePool

    init(db: DatabasePool) {
        self.db = db
    }

    func allTags() throws -> [Tag] {
        try db.read { db in
            try Tag.order(Column("name")).fetchAll(db)
        }
    }

    func tags(for fileId: Int64) throws -> [Tag] {
        try db.read { db in
            let sql = """
                SELECT tags.* FROM tags
                JOIN file_tags ON file_tags.tag_id = tags.id
                WHERE file_tags.file_id = ?
                ORDER BY tags.name
            """
            return try Tag.fetchAll(db, sql: sql, arguments: [fileId])
        }
    }

    func setTags(_ tagNames: [String], for fileId: Int64) throws {
        try db.write { db in
            // Remove existing
            try FileTag.filter(Column("file_id") == fileId).deleteAll(db)
            // Insert or find each tag, then link
            for name in tagNames {
                var tag = try Tag.filter(Column("name") == name).fetchOne(db)
                    ?? Tag(id: nil, name: name, colorHex: nil)
                if tag.id == nil { try tag.insert(db) }
                try FileTag(fileId: fileId, tagId: tag.id!).insert(db)
            }
        }
    }
}
