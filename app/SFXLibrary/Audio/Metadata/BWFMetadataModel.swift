import Foundation

// MARK: - Field registry
//
// Ported from ptpeep's BWFParser. The full set of BWF/iXML/RIFF-INFO fields a
// metadata profile can choose to display, plus the comprehensive parser that
// reads them. SoundSearch indexes these into the database (see LibraryService),
// then renders the active profile's columns via AudioFile.displayValue(for:).

enum BWFFieldKey: String, CaseIterable, Identifiable {
    // iXML chunk
    case ixmlScene       = "ixml.scene"
    case ixmlTake        = "ixml.take"
    case ixmlTape        = "ixml.tape"
    case ixmlNote        = "ixml.note"
    case ixmlCircled     = "ixml.circled"
    case ixmlTrackNames  = "ixml.trackNames"
    case ixmlCategory    = "ixml.category"      // UCS — SoundSearch addition
    case ixmlSubCategory = "ixml.subCategory"   // UCS — SoundSearch addition
    // iXML production
    case ixmlProject     = "ixml.project"
    case ixmlFileUID     = "ixml.fileUID"
    case ixmlUbits       = "ixml.ubits"
    case ixmlWildTrack   = "ixml.wildTrack"
    case ixmlNoGood      = "ixml.noGood"
    case ixmlFalseStart  = "ixml.falseStart"
    case ixmlSyncPoint   = "ixml.syncPoint"
    // iXML speed / timecode
    case ixmlMasterSpeed    = "ixml.masterSpeed"
    case ixmlTimecodeRate   = "ixml.timecodeRate"
    case ixmlTimecodeFlag   = "ixml.timecodeFlag"
    case ixmlFileSampleRate = "ixml.fileSampleRate"
    case ixmlDigitizerRate  = "ixml.digitizerRate"
    // bext chunk
    case bextDescription   = "bext.description"
    case bextOriginator    = "bext.originator"
    case bextOriginatorRef = "bext.originatorRef"
    case bextDate          = "bext.date"
    case bextTime          = "bext.time"
    case bextTimeReference = "bext.timeReference"
    case bextVersion       = "bext.version"
    case bextUMID          = "bext.umid"
    case bextLoudness      = "bext.loudnessValue"
    case bextLoudnessRange = "bext.loudnessRange"
    case bextMaxTruePeak   = "bext.maxTruePeak"
    case bextMaxMomentary  = "bext.maxMomentary"
    case bextMaxShortTerm  = "bext.maxShortTerm"
    case bextCodingHistory = "bext.codingHistory"
    case bextTimeReferenceSamples = "bext.timeReferenceSamples"
    // iXML file family / location
    case ixmlFamilyName   = "ixml.familyName"
    case ixmlFamilyUID    = "ixml.familyUID"
    case ixmlFileSetIndex = "ixml.fileSetIndex"
    case ixmlTotalFiles   = "ixml.totalFiles"
    case ixmlLocationName = "ixml.locationName"
    case ixmlLocationGPS  = "ixml.locationGPS"
    // File attributes (not BWF metadata — sourced from the file itself)
    case filePath         = "file.path"
    case containingFolder = "file.folder"
    // RIFF LIST/INFO
    case infoTitle      = "info.title"
    case infoArtist     = "info.artist"
    case infoComment    = "info.comment"
    case infoCopyright  = "info.copyright"
    case infoGenre      = "info.genre"
    case infoCreated    = "info.created"
    case infoSoftware   = "info.software"
    case infoEngineer   = "info.engineer"
    case infoSource     = "info.source"
    case infoProduct    = "info.product"
    case infoSubject    = "info.subject"
    case infoTechnician = "info.technician"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ixmlScene:       return "Scene"
        case .ixmlTake:        return "Take"
        case .ixmlTape:        return "Roll"
        case .ixmlNote:        return "Note"
        case .ixmlCircled:     return "Circled"
        case .ixmlTrackNames:  return "Channel Names"
        case .ixmlCategory:    return "UCS Cat"
        case .ixmlSubCategory: return "UCS Sub"
        case .ixmlProject:        return "Project"
        case .ixmlFileUID:        return "File UID"
        case .ixmlUbits:          return "User Bits"
        case .ixmlWildTrack:      return "Wild Track"
        case .ixmlNoGood:         return "No Good"
        case .ixmlFalseStart:     return "False Start"
        case .ixmlSyncPoint:      return "Sync Point"
        case .ixmlMasterSpeed:    return "Master Speed"
        case .ixmlTimecodeRate:   return "TC Rate"
        case .ixmlTimecodeFlag:   return "DF/NDF"
        case .ixmlFileSampleRate: return "File Rate"
        case .ixmlDigitizerRate:  return "Digitizer Rate"
        case .bextDescription:   return "Description"
        case .bextOriginator:    return "Originator"
        case .bextOriginatorRef: return "Originator Ref"
        case .bextDate:          return "Date"
        case .bextTime:          return "Time"
        case .bextTimeReference: return "TC Ref"
        case .bextVersion:       return "BWF Version"
        case .bextUMID:          return "UMID"
        case .bextLoudness:      return "Integrated Loudness"
        case .bextLoudnessRange: return "Loudness Range"
        case .bextMaxTruePeak:   return "Max True Peak"
        case .bextMaxMomentary:  return "Max Momentary"
        case .bextMaxShortTerm:  return "Max Short-Term"
        case .bextCodingHistory: return "Coding History"
        case .bextTimeReferenceSamples: return "TC Ref (samples)"
        case .ixmlFamilyName:   return "Family Name"
        case .ixmlFamilyUID:    return "Family UID"
        case .ixmlFileSetIndex: return "File Set Index"
        case .ixmlTotalFiles:   return "Total Files"
        case .ixmlLocationName: return "Location"
        case .ixmlLocationGPS:  return "GPS"
        case .filePath:       return "File Path"
        case .containingFolder: return "Containing Folder"
        case .infoTitle:      return "Title"
        case .infoArtist:     return "Artist"
        case .infoComment:    return "Comment"
        case .infoCopyright:  return "Copyright"
        case .infoGenre:      return "Genre"
        case .infoCreated:    return "Created"
        case .infoSoftware:   return "Software"
        case .infoEngineer:   return "Engineer"
        case .infoSource:     return "Source"
        case .infoProduct:    return "Album/Product"
        case .infoSubject:    return "Subject"
        case .infoTechnician: return "Technician"
        }
    }

    static let defaults: [BWFFieldKey] = [
        .bextDescription, .ixmlCategory, .ixmlSubCategory, .bextTimeReference, .ixmlNote
    ]

    /// True for fields SoundSearch persists in the database and can therefore
    /// display. Non-persisted fields render as "—".
    var isPersisted: Bool {
        switch self {
        case .ixmlWildTrack, .ixmlNoGood, .ixmlFalseStart, .ixmlSyncPoint,
             .ixmlDigitizerRate, .ixmlFamilyUID, .ixmlFileSetIndex, .ixmlTotalFiles,
             .ixmlLocationGPS:
            return false
        default:
            return true
        }
    }

    /// Underlying text column used for searching this field, or nil for
    /// numeric/computed/non-persisted fields that can't be text-searched.
    var searchColumn: String? {
        switch self {
        case .ixmlScene:        return "bwf_scene"
        case .ixmlTake:         return "bwf_take"
        case .ixmlTape:         return "tape_name"
        case .ixmlNote:         return "ixml_note"
        case .ixmlCircled:      return "ixml_circled"
        case .ixmlTrackNames:   return "ixml_track_names"
        case .ixmlCategory:     return "ucs_category"
        case .ixmlSubCategory:  return "ucs_sub_category"
        case .ixmlProject:      return "ixml_project"
        case .ixmlFileUID:      return "ixml_file_uid"
        case .ixmlUbits:        return "ixml_ubits"
        case .ixmlMasterSpeed:  return "ixml_master_speed"
        case .ixmlTimecodeRate: return "ixml_timecode_rate"
        case .ixmlTimecodeFlag: return "ixml_timecode_flag"
        case .ixmlFileSampleRate: return "ixml_file_sample_rate"
        case .ixmlFamilyName:   return "ixml_family_name"
        case .ixmlLocationName: return "ixml_location_name"
        case .filePath:         return "file_url"
        case .containingFolder: return "file_url"
        case .bextDescription:  return "bwf_description"
        case .bextOriginator:   return "bwf_originator"
        case .bextOriginatorRef: return "bwf_originator_ref"
        case .bextDate:         return "origination_date"
        case .bextTime:         return "bwf_time"
        case .bextUMID:         return "bwf_umid"
        case .bextCodingHistory: return "bwf_coding_history"
        case .infoTitle:      return "info_title"
        case .infoArtist:     return "info_artist"
        case .infoComment:    return "info_comment"
        case .infoCopyright:  return "info_copyright"
        case .infoGenre:      return "info_genre"
        case .infoCreated:    return "info_created"
        case .infoSoftware:   return "info_software"
        case .infoEngineer:   return "info_engineer"
        case .infoSource:     return "info_source"
        case .infoProduct:    return "info_product"
        case .infoSubject:    return "info_subject"
        case .infoTechnician: return "info_technician"
        case .bextTimeReference, .bextTimeReferenceSamples, .bextVersion,
             .bextLoudness, .bextLoudnessRange, .bextMaxTruePeak, .bextMaxMomentary,
             .bextMaxShortTerm, .ixmlWildTrack, .ixmlNoGood, .ixmlFalseStart,
             .ixmlSyncPoint, .ixmlDigitizerRate, .ixmlFamilyUID, .ixmlFileSetIndex,
             .ixmlTotalFiles, .ixmlLocationGPS:
            return nil
        }
    }

    /// True when `searchColumn` is part of the FTS5 index (fast scoped search).
    /// Others fall back to a LIKE query. Keep in sync with the v5 FTS table.
    var isFTSColumn: Bool {
        switch self {
        case .bextDescription, .bextOriginator, .ixmlScene, .ixmlTake, .ixmlTape,
             .ixmlNote, .ixmlCategory, .ixmlSubCategory, .ixmlTrackNames,
             .bextCodingHistory, .infoTitle, .infoArtist, .infoComment, .infoGenre:
            return true
        default:
            return false
        }
    }

    var group: FieldGroup {
        switch self {
        case .ixmlScene, .ixmlTake, .ixmlTape, .ixmlNote, .ixmlCircled,
             .ixmlTrackNames, .ixmlCategory, .ixmlSubCategory:
            return .ixml
        case .ixmlProject, .ixmlFileUID, .ixmlUbits, .ixmlWildTrack,
             .ixmlNoGood, .ixmlFalseStart, .ixmlSyncPoint:
            return .production
        case .ixmlMasterSpeed, .ixmlTimecodeRate, .ixmlTimecodeFlag,
             .ixmlFileSampleRate, .ixmlDigitizerRate:
            return .speedTC
        case .bextDescription, .bextOriginator, .bextOriginatorRef, .bextDate,
             .bextTime, .bextTimeReference, .bextVersion, .bextUMID, .bextLoudness,
             .bextLoudnessRange, .bextMaxTruePeak, .bextMaxMomentary,
             .bextMaxShortTerm, .bextCodingHistory, .bextTimeReferenceSamples:
            return .bext
        case .ixmlFamilyName, .ixmlFamilyUID, .ixmlFileSetIndex, .ixmlTotalFiles,
             .ixmlLocationName, .ixmlLocationGPS, .filePath, .containingFolder:
            return .fileFamily
        case .infoTitle, .infoArtist, .infoComment, .infoCopyright, .infoGenre,
             .infoCreated, .infoSoftware, .infoEngineer, .infoSource, .infoProduct,
             .infoSubject, .infoTechnician:
            return .info
        }
    }
}

/// Source-based grouping for the field picker UI.
enum FieldGroup: String, CaseIterable, Identifiable {
    case ixml       = "iXML"
    case production = "Production"
    case speedTC    = "Speed / Timecode"
    case fileFamily = "File / Location"
    case bext       = "Broadcast WAV (bext)"
    case info       = "RIFF INFO"

    var id: String { rawValue }
    var title: String { rawValue }

    /// Fields belonging to this group, in declaration order.
    var fields: [BWFFieldKey] { BWFFieldKey.allCases.filter { $0.group == self } }
}

// MARK: - Display helpers (module-internal — reused by AudioFile.displayValue)

/// Format a sample position as HH:MM:SS:FF timecode.
func bwfFormatTimecode(samples: Int64, sampleRate: Double, frameRate: Double = 24) -> String? {
    guard sampleRate > 0 else { return nil }
    let secs   = Double(samples) / sampleRate
    let h      = Int(secs / 3600)
    let m      = Int(secs.truncatingRemainder(dividingBy: 3600) / 60)
    let s      = Int(secs.truncatingRemainder(dividingBy: 60))
    let fps    = frameRate > 0 ? frameRate : 24
    let frames = Int((secs - floor(secs)) * fps)
    return String(format: "%02d:%02d:%02d:%02d", h, m, s, frames)
}

/// Turn a rate fraction ("30000/1001") or plain fps ("23.976") into "29.97 fps".
func bwfHumanizeFPS(_ raw: String) -> String {
    let fps: Double?
    if raw.contains("/") {
        let p = raw.split(separator: "/")
        fps = (p.count == 2) ? Double(p[0]).flatMap { n in Double(p[1]).map { n / $0 } } : nil
    } else {
        fps = Double(raw)
    }
    guard let f = fps, f > 0 else { return raw }
    if abs(f - f.rounded()) < 0.001 { return "\(Int(f.rounded())) fps" }
    let trimmed = String(format: "%.3f", f)
        .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    return trimmed + " fps"
}

/// Turn a sample-rate string ("48000") into "48 kHz" / "44.1 kHz".
func bwfHumanizeRate(_ raw: String?) -> String? {
    guard let raw, let hz = Double(raw), hz > 0 else { return raw }
    let k = hz / 1000
    return abs(k - k.rounded()) < 0.05 ? "\(Int(k.rounded())) kHz" : String(format: "%.1f kHz", k)
}

// MARK: - Metadata model

struct BWFMetadata {
    // iXML
    var scene:         String?
    var take:          String?
    var tape:          String?
    var note:          String?
    var circled:       String?
    var category:      String?   // UCS CATEGORY
    var subCategory:   String?   // UCS SUBCATEGORY
    var trackNames:    [(channel: Int, name: String)] = []  // from TRACK_LIST
    // iXML production
    var project:       String?
    var fileUID:       String?
    var ubits:         String?
    var wildTrack:     Bool?
    var noGood:        Bool?
    var falseStart:    Bool?
    var syncPoints:    [Int64] = []
    // iXML speed / timecode
    var masterSpeed:    String?
    var timecodeRate:   String?
    var timecodeFlag:   String?
    var fileSampleRate: String?
    var digitizerRate:  String?
    // iXML file family / location
    var familyName:   String?
    var familyUID:    String?
    var fileSetIndex: String?
    var totalFiles:   String?
    var locationName: String?
    var locationGPS:  String?
    // RIFF LIST/INFO
    var infoTitle:      String?
    var infoArtist:     String?
    var infoComment:    String?
    var infoCopyright:  String?
    var infoGenre:      String?
    var infoCreated:    String?
    var infoSoftware:   String?
    var infoEngineer:   String?
    var infoSource:     String?
    var infoProduct:    String?
    var infoSubject:    String?
    var infoTechnician: String?
    // bext
    var description:   String?
    var originator:    String?
    var originatorRef: String?
    var date:          String?
    var time:          String?
    var timeReference: Int64?   // samples since midnight (raw)
    var version:       Int?
    var umid:          String?
    var loudness:      Double?  // LUFS
    var loudnessRange: Double?  // LU
    var maxTruePeak:   Double?  // dBTP
    var maxMomentary:  Double?  // LUFS
    var maxShortTerm:  Double?  // LUFS
    var codingHistory: String?

    /// Denormalized channel-name string for storage/display ("Ch1: Boom  Ch2: Lav").
    var trackNamesJoined: String? {
        guard !trackNames.isEmpty else { return nil }
        return trackNames.map { "Ch\($0.channel): \($0.name)" }.joined(separator: "  ")
    }
}

// MARK: - Parser

enum BWFParser {
    static func parse(url: URL) -> BWFMetadata? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return parse(data: data)
    }

    /// Parse from already-extracted chunk blobs (e.g. from RIFFParser's single
    /// streaming pass) — avoids re-reading/mapping the whole file. Each blob is a
    /// standalone chunk payload; `info` is the LIST payload starting with "INFO".
    static func parse(bext: Data?, ixml: Data?, info: Data?) -> BWFMetadata {
        var meta = BWFMetadata()
        if let bext { parseBext(data: bext, start: 0, size: bext.count, into: &meta) }
        if let ixml { parseIXML(data: ixml, start: 0, size: ixml.count, into: &meta) }
        if let info, info.count >= 4,
           String(bytes: info[info.startIndex..<info.startIndex+4], encoding: .ascii) == "INFO" {
            parseInfoList(data: info, start: 4, size: info.count - 4, into: &meta)
        }
        applyDescriptionScheme(into: &meta)
        return meta
    }

    static func parse(data: Data) -> BWFMetadata? {
        guard data.count > 12,
              data[0..<4] == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8) else { return nil }

        var meta   = BWFMetadata()
        var hasBWF = false
        var offset = 12

        while offset + 8 <= data.count {
            let id        = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let size      = Int(data.bwfReadUInt32LE(at: offset + 4))
            let dataStart = offset + 8

            switch id {
            case "bext":
                parseBext(data: data, start: dataStart, size: size, into: &meta)
                hasBWF = true
            case "iXML":
                parseIXML(data: data, start: dataStart, size: size, into: &meta)
                hasBWF = true
            case "LIST":
                if dataStart + 4 <= data.count,
                   String(bytes: data[dataStart..<dataStart+4], encoding: .ascii) == "INFO" {
                    parseInfoList(data: data, start: dataStart + 4, size: size - 4, into: &meta)
                    hasBWF = true
                }
            default:
                break
            }

            let next = dataStart + size + (size & 1)
            guard next > offset else { break }
            offset = next
        }

        applyDescriptionScheme(into: &meta)
        return hasBWF ? meta : nil
    }

    /// Sound Devices recorders pack `KEY=value` lines into the bext Description.
    private static func applyDescriptionScheme(into meta: inout BWFMetadata) {
        guard let desc = meta.description, desc.contains("=") else { return }

        var fields: [String: String] = [:]
        for line in desc.split(whereSeparator: { $0.isNewline }) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let first = t.first, first == "d" || first == "s",
                  let eq = t.firstIndex(of: "="),
                  t.index(after: t.startIndex) < eq else { continue }
            let key = t[t.index(after: t.startIndex)..<eq].uppercased()
            let val = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !val.isEmpty, fields[key] == nil { fields[key] = val }
        }

        func fill(_ kp: WritableKeyPath<BWFMetadata, String?>, _ key: String) {
            if meta[keyPath: kp] == nil, let v = fields[key] { meta[keyPath: kp] = v }
        }
        fill(\.scene,   "SCENE")
        fill(\.take,    "TAKE")
        fill(\.tape,    "TAPE")
        fill(\.note,    "NOTE")
        fill(\.ubits,   "UBITS")
        fill(\.circled, "CIRCLED")

        if let raw = fields["SPEED"] ?? fields["FRAMERATE"] {
            let (rate, flag) = Self.splitRateFlag(raw)
            if meta.timecodeRate == nil, let rate { meta.timecodeRate = rate }
            if meta.timecodeFlag == nil, let flag { meta.timecodeFlag = flag }
        }
    }

    private static func splitRateFlag(_ s: String) -> (rate: String?, flag: String?) {
        func normFlag(_ f: Substring) -> String {
            let u = f.uppercased()
            if u.hasPrefix("ND") { return "NDF" }
            if u.hasPrefix("DF") { return "DF" }
            return u
        }
        if let dash = s.firstIndex(of: "-") {
            let rate = String(s[..<dash])
            let flag = s[s.index(after: dash)...]
            return (Double(rate) != nil ? rate : nil, flag.isEmpty ? nil : normFlag(flag))
        }
        let split = s.firstIndex { !($0.isNumber || $0 == ".") } ?? s.endIndex
        let rate = String(s[..<split])
        let flag = s[split...]
        return (Double(rate) != nil ? rate : nil, flag.isEmpty ? nil : normFlag(flag))
    }

    // MARK: bext

    private static func parseBext(data: Data, start: Int, size: Int, into meta: inout BWFMetadata) {
        // EBU Tech 3285 bext chunk layout (offsets relative to chunk data start):
        //   0 Description 256 | 256 Originator 32 | 288 OriginatorReference 32
        // 320 OriginationDate 10 | 330 OriginationTime 8
        // 338 TimeReferenceLow u32 | 342 TimeReferenceHigh u32 | 346 Version u16
        // 348 UMID 64 | 412..420 Loudness fields i16 (V2+) | 602 CodingHistory
        func fixedStr(_ off: Int, _ len: Int) -> String? {
            let s = start + off, e = min(s + len, data.count)
            guard s < e else { return nil }
            let trimmed = data[s..<e].prefix(while: { $0 != 0 })
            guard !trimmed.isEmpty else { return nil }
            return String(bytes: trimmed, encoding: .utf8)
                ?? String(bytes: trimmed, encoding: .isoLatin1)
        }

        meta.description   = fixedStr(0,   256)
        meta.originator    = fixedStr(256,  32)
        meta.originatorRef = fixedStr(288,  32)
        meta.date          = fixedStr(320,  10)
        meta.time          = fixedStr(330,   8)

        if size >= 346, start + 345 < data.count {
            let lo = UInt64(data.bwfReadUInt32LE(at: start + 338))
            let hi = UInt64(data.bwfReadUInt32LE(at: start + 342))
            meta.timeReference = Int64(bitPattern: (hi << 32) | lo)
        }
        if size >= 348, start + 347 < data.count {
            meta.version = Int(data.bwfReadUInt16LE(at: start + 346))
        }
        if size >= 412, start + 411 < data.count {
            let umidBytes = data[(start+348)..<min(start+412, data.count)]
            if umidBytes.contains(where: { $0 != 0 }) {
                meta.umid = umidBytes.map { String(format: "%02X", $0) }.joined()
            }
        }
        if let ver = meta.version, ver >= 2, size >= 422, start + 421 < data.count {
            func loudnessField(at off: Int) -> Double? {
                let raw = data.bwfReadInt16LE(at: start + off)
                guard raw != Int16(bitPattern: 0x7FFF) else { return nil }
                return Double(raw) / 100.0
            }
            meta.loudness      = loudnessField(at: 412)
            meta.loudnessRange = loudnessField(at: 414)
            meta.maxTruePeak   = loudnessField(at: 416)
            meta.maxMomentary  = loudnessField(at: 418)
            meta.maxShortTerm  = loudnessField(at: 420)
        }
        if size > 602 {
            let s = start + 602, e = min(s + size - 602, data.count)
            if s < e {
                let trimmed = data[s..<e].prefix(while: { $0 != 0 })
                if !trimmed.isEmpty {
                    meta.codingHistory = String(bytes: trimmed, encoding: .utf8)
                        ?? String(bytes: trimmed, encoding: .isoLatin1)
                }
            }
        }
    }

    // MARK: iXML

    private static func parseIXML(data: Data, start: Int, size: Int, into meta: inout BWFMetadata) {
        let end = min(start + size, data.count)
        guard start < end,
              let xml = String(data: data[start..<end], encoding: .utf8)
                     ?? String(data: data[start..<end], encoding: .isoLatin1)
        else { return }

        meta.scene       = tag(in: xml, "SCENE")
        meta.take        = tag(in: xml, "TAKE")
        meta.tape        = tag(in: xml, "TAPE")
        meta.note        = tag(in: xml, "NOTE")
        meta.circled     = tag(in: xml, "CIRCLED")
        meta.category    = tag(in: xml, "CATEGORY")      // UCS
        meta.subCategory = tag(in: xml, "SUBCATEGORY")   // UCS

        meta.project = tag(in: xml, "PROJECT")
        meta.fileUID = tag(in: xml, "FILE_UID")
        meta.ubits   = tag(in: xml, "UBITS")

        let takeType = tag(in: xml, "TAKE_TYPE")?.uppercased() ?? ""
        func flag(_ name: String, _ token: String) -> Bool? {
            if let v = tag(in: xml, name)?.uppercased() {
                return v == "TRUE" || v == "1" || v == "YES"
            }
            return takeType.contains(token) ? true : nil
        }
        meta.wildTrack  = flag("WILD_TRACK",  "WILD_TRACK")
        meta.noGood     = flag("NO_GOOD",     "NO_GOOD")
        meta.falseStart = flag("FALSE_START", "FALSE_START")

        meta.masterSpeed    = tag(in: xml, "MASTER_SPEED")
        meta.timecodeRate   = tag(in: xml, "TIMECODE_RATE")
        meta.timecodeFlag   = tag(in: xml, "TIMECODE_FLAG")
        meta.fileSampleRate = tag(in: xml, "FILE_SAMPLE_RATE")
        meta.digitizerRate  = tag(in: xml, "DIGITIZER_SAMPLE_RATE")

        meta.familyName   = tag(in: xml, "FAMILY_NAME")
        meta.familyUID    = tag(in: xml, "FAMILY_UID")
        meta.fileSetIndex = tag(in: xml, "FILE_SET_INDEX")
        meta.totalFiles   = tag(in: xml, "TOTAL_FILES")

        meta.locationName = tag(in: xml, "LOCATION_NAME")
        meta.locationGPS  = tag(in: xml, "LOCATION_GPS")

        var spFrom = xml.startIndex
        while let p1 = xml.range(of: "<SYNC_POINT>", range: spFrom..<xml.endIndex),
              let p2 = xml.range(of: "</SYNC_POINT>", range: p1.upperBound..<xml.endIndex) {
            let spXML = String(xml[p1.upperBound..<p2.lowerBound])
            let lo = Int64(tag(in: spXML, "SYNC_POINT_LOW")  ?? "") ?? 0
            let hi = Int64(tag(in: spXML, "SYNC_POINT_HIGH") ?? "") ?? 0
            meta.syncPoints.append((hi << 32) | lo)
            spFrom = p2.upperBound
        }

        var searchFrom = xml.startIndex
        while let t1 = xml.range(of: "<TRACK>", range: searchFrom..<xml.endIndex),
              let t2 = xml.range(of: "</TRACK>", range: t1.upperBound..<xml.endIndex) {
            let trackXML = String(xml[t1.upperBound..<t2.lowerBound])
            if let name = tag(in: trackXML, "NAME"),
               let chStr = tag(in: trackXML, "CHANNEL_INDEX"),
               let ch = Int(chStr) {
                meta.trackNames.append((channel: ch, name: name))
            }
            searchFrom = t2.upperBound
        }
        meta.trackNames.sort { $0.channel < $1.channel }
    }

    private static func tag(in xml: String, _ name: String) -> String? {
        guard let r1 = xml.range(of: "<\(name)>"),
              let r2 = xml.range(of: "</\(name)>", range: r1.upperBound..<xml.endIndex)
        else { return nil }
        let v = String(xml[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    // MARK: RIFF LIST/INFO

    private static func parseInfoList(data: Data, start: Int, size: Int, into meta: inout BWFMetadata) {
        var p = start
        let end = min(start + size, data.count)
        while p + 8 <= end {
            let id  = String(bytes: data[p..<p+4], encoding: .ascii) ?? ""
            let len = Int(data.bwfReadUInt32LE(at: p + 4))
            let vs  = p + 8, ve = min(vs + len, data.count)
            guard vs <= ve else { break }
            let trimmed = data[vs..<ve].prefix(while: { $0 != 0 })
            let value = String(bytes: trimmed, encoding: .utf8)
                     ?? String(bytes: trimmed, encoding: .isoLatin1)
            if let value, !value.isEmpty {
                switch id {
                case "INAM": meta.infoTitle      = value
                case "IART": meta.infoArtist     = value
                case "ICMT": meta.infoComment    = value
                case "ICOP": meta.infoCopyright  = value
                case "IGNR": meta.infoGenre      = value
                case "ICRD": meta.infoCreated    = value
                case "ISFT": meta.infoSoftware   = value
                case "IENG": meta.infoEngineer   = value
                case "ISRC": meta.infoSource     = value
                case "IPRD": meta.infoProduct    = value
                case "ISBJ": meta.infoSubject    = value
                case "ITCH": meta.infoTechnician = value
                default: break
                }
            }
            p = vs + len + (len & 1)
        }
    }
}

// MARK: - Data helpers (file-private)

private extension Data {
    func bwfReadUInt32LE(at i: Int) -> UInt32 {
        guard i + 3 < count else { return 0 }
        return UInt32(self[i]) | UInt32(self[i+1]) << 8
             | UInt32(self[i+2]) << 16 | UInt32(self[i+3]) << 24
    }
    func bwfReadUInt16LE(at i: Int) -> UInt16 {
        guard i + 1 < count else { return 0 }
        return UInt16(self[i]) | UInt16(self[i+1]) << 8
    }
    func bwfReadInt16LE(at i: Int) -> Int16 {
        Int16(bitPattern: bwfReadUInt16LE(at: i))
    }
}
