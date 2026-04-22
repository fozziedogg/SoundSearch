import Foundation
import GRDB

/// Represents one audio file in the library database.
struct AudioFile: Identifiable, Hashable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var fileURL: String
    var bookmarkData: Data?
    var filename: String
    var fileSize: Int64
    var mtime: Double
    var format: String              // "WAV" | "AIFF"

    // Technical (read-only from file)
    var duration: Double?
    var sampleRate: Int?
    var bitDepth: Int?
    var channels: Int?
    var lufs: Double?

    // BWF / iXML (mirrored — writes go back to the file)
    var bwfDescription: String
    var bwfOriginator: String
    var bwfScene: String
    var bwfTake: String
    var bwfTimeRefLow: Int64
    var bwfTimeRefHigh: Int64
    var originationDate: String     // BEXT "YYYY-MM-DD"
    var tapeName: String            // iXML TAPE
    var ixmlNote: String            // iXML NOTE
    var ucsCategory: String         // iXML CATEGORY
    var ucsSubCategory: String      // iXML SUBCATEGORY
    // DB-only custom metadata
    var notes: String
    var starRating: Int             // 0–5
    var dateAdded: Date
    var lastModified: Date

    static var databaseTableName = "audio_files"

    enum CodingKeys: String, CodingKey {
        case id, filename, mtime, format, duration, channels, lufs, notes
        case fileURL         = "file_url"
        case bookmarkData    = "bookmark_data"
        case fileSize        = "file_size"
        case sampleRate      = "sample_rate"
        case bitDepth        = "bit_depth"
        case bwfDescription  = "bwf_description"
        case bwfOriginator   = "bwf_originator"
        case bwfScene        = "bwf_scene"
        case bwfTake         = "bwf_take"
        case bwfTimeRefLow   = "bwf_time_ref_low"
        case bwfTimeRefHigh  = "bwf_time_ref_high"
        case originationDate = "origination_date"
        case tapeName        = "tape_name"
        case ixmlNote        = "ixml_note"
        case ucsCategory     = "ucs_category"
        case ucsSubCategory  = "ucs_sub_category"
        case starRating      = "star_rating"
        case dateAdded       = "date_added"
        case lastModified    = "last_modified"
    }

    enum Columns {
        static let id            = Column("id")
        static let fileURL       = Column("file_url")
        static let filename      = Column("filename")
        static let mtime         = Column("mtime")
        static let starRating    = Column("star_rating")
        static let bwfDescription = Column("bwf_description")
        static let duration      = Column("duration")
        static let sampleRate    = Column("sample_rate")
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
