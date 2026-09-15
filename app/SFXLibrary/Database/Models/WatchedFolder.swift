import Foundation
import GRDB

struct WatchedFolder: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var path: String
    var bookmarkData: Data
    var dateAdded: Date
    var lastScanned: Date?
    /// Disk audio-file count recorded at the end of the last scan. nil = never scanned.
    var scannedFileCount: Int?
    /// Durable location identity (v6) — see VolumeIndex. `path` is regenerated from these.
    var volumeUUID: String?
    var volumeRelativePath: String?

    static var databaseTableName = "watched_folders"

    enum CodingKeys: String, CodingKey {
        case id, path
        case bookmarkData    = "bookmark_data"
        case dateAdded       = "date_added"
        case lastScanned     = "last_scanned"
        case scannedFileCount = "scanned_file_count"
        case volumeUUID         = "volume_uuid"
        case volumeRelativePath = "volume_relative_path"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
