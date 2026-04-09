import Foundation
import GRDB

struct Tag: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var colorHex: String?

    static var databaseTableName = "tags"

    enum CodingKeys: String, CodingKey {
        case id, name
        case colorHex = "color_hex"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct FileTag: Codable, FetchableRecord, PersistableRecord {
    var fileId: Int64
    var tagId: Int64

    static var databaseTableName = "file_tags"

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case tagId  = "tag_id"
    }
}
