import Foundation
import GRDB

// MARK: - Project (global, cross-database smart folder)

struct Project: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var sortOrder: Int

    static var databaseTableName = "projects"

    enum CodingKeys: String, CodingKey {
        case id, name
        case sortOrder = "sort_order"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - ProjectFile (join: project ↔ file_url)

struct ProjectFile: Codable, FetchableRecord, PersistableRecord {
    var projectId: Int64
    var fileURL:   String
    var dateAdded: Date

    static var databaseTableName = "project_files"

    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case fileURL   = "file_url"
        case dateAdded = "date_added"
    }
}
