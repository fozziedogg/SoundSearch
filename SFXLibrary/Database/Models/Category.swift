import Foundation
import GRDB

struct Category: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var parentId: Int64?
    var sortOrder: Int

    static var databaseTableName = "categories"

    enum CodingKeys: String, CodingKey {
        case id, name
        case parentId  = "parent_id"
        case sortOrder = "sort_order"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct FileCategory: Codable, FetchableRecord, PersistableRecord {
    var fileId: Int64
    var categoryId: Int64

    static var databaseTableName = "file_categories"

    enum CodingKeys: String, CodingKey {
        case fileId     = "file_id"
        case categoryId = "category_id"
    }
}
