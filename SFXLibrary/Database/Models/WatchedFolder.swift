import Foundation
import GRDB

struct WatchedFolder: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var path: String
    var bookmarkData: Data
    var dateAdded: Date
    var lastScanned: Date?

    static var databaseTableName = "watched_folders"

    enum CodingKeys: String, CodingKey {
        case id, path
        case bookmarkData = "bookmark_data"
        case dateAdded    = "date_added"
        case lastScanned  = "last_scanned"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
