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

    // Rich BWF metadata (v5) — bext
    var bwfOriginatorRef: String = ""
    var bwfTime: String = ""                // BEXT OriginationTime "HH:MM:SS"
    var bwfVersion: Int? = nil
    var bwfUMID: String = ""
    var bwfCodingHistory: String = ""
    var loudnessRange: Double? = nil        // LU
    var maxTruePeak: Double? = nil          // dBTP
    var maxMomentary: Double? = nil         // LUFS
    var maxShortTerm: Double? = nil         // LUFS
    // Rich BWF metadata (v5) — iXML
    var ixmlCircled: String = ""
    var ixmlTrackNames: String = ""         // denormalized "Ch1: Boom  Ch2: Lav"
    var ixmlProject: String = ""
    var ixmlFileUID: String = ""
    var ixmlUbits: String = ""
    var ixmlFileSampleRate: String = ""
    var ixmlMasterSpeed: String = ""
    var ixmlTimecodeRate: String = ""
    var ixmlTimecodeFlag: String = ""
    var ixmlFamilyName: String = ""
    var ixmlLocationName: String = ""
    // Rich BWF metadata (v5) — RIFF LIST/INFO
    var infoTitle: String = ""
    var infoArtist: String = ""
    var infoComment: String = ""
    var infoCopyright: String = ""
    var infoGenre: String = ""
    var infoCreated: String = ""
    var infoSoftware: String = ""
    var infoEngineer: String = ""
    var infoSource: String = ""
    var infoProduct: String = ""
    var infoSubject: String = ""
    var infoTechnician: String = ""

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
        case bwfOriginatorRef   = "bwf_originator_ref"
        case bwfTime            = "bwf_time"
        case bwfVersion         = "bwf_version"
        case bwfUMID            = "bwf_umid"
        case bwfCodingHistory   = "bwf_coding_history"
        case loudnessRange      = "loudness_range"
        case maxTruePeak        = "max_true_peak"
        case maxMomentary       = "max_momentary"
        case maxShortTerm       = "max_short_term"
        case ixmlCircled        = "ixml_circled"
        case ixmlTrackNames     = "ixml_track_names"
        case ixmlProject        = "ixml_project"
        case ixmlFileUID        = "ixml_file_uid"
        case ixmlUbits          = "ixml_ubits"
        case ixmlFileSampleRate = "ixml_file_sample_rate"
        case ixmlMasterSpeed    = "ixml_master_speed"
        case ixmlTimecodeRate   = "ixml_timecode_rate"
        case ixmlTimecodeFlag   = "ixml_timecode_flag"
        case ixmlFamilyName     = "ixml_family_name"
        case ixmlLocationName   = "ixml_location_name"
        case infoTitle      = "info_title"
        case infoArtist     = "info_artist"
        case infoComment    = "info_comment"
        case infoCopyright  = "info_copyright"
        case infoGenre      = "info_genre"
        case infoCreated    = "info_created"
        case infoSoftware   = "info_software"
        case infoEngineer   = "info_engineer"
        case infoSource     = "info_source"
        case infoProduct    = "info_product"
        case infoSubject    = "info_subject"
        case infoTechnician = "info_technician"
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
