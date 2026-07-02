import Foundation
import GRDB

/// Orchestrates ingesting files from disk into the database,
/// reading their technical metadata and BWF fields.
final class LibraryService {
    private let db: DatabasePool
    private let fileRepo: AudioFileRepository

    init(db: DatabasePool) {
        self.db       = db
        self.fileRepo = AudioFileRepository(db: db)
    }

    // MARK: - Ingest

    func ingestFile(at url: URL, force: Bool = false) async throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size  = attrs[.size] as? Int64 else { return }  // file disappeared — skip silently

        let mtimeDouble = mtime.timeIntervalSince1970

        // Skip if already in DB and unchanged (unless force rescan)
        if !force,
           let existing = try? fileRepo.fetch(fileURL: url.path),
           existing.mtime == mtimeDouble { return }

        var file = AudioFile(
            id: nil,
            fileURL:    url.path,
            bookmarkData: nil,
            filename:   Self.ptSafe(url.lastPathComponent),
            fileSize:   size,
            mtime:      mtimeDouble,
            format:     url.pathExtension.uppercased(),
            duration:   nil,
            sampleRate: nil,
            bitDepth:   nil,
            channels:   nil,
            lufs:       nil,
            bwfDescription: "",
            bwfOriginator:  "",
            bwfScene:       "",
            bwfTake:        "",
            bwfTimeRefLow:  0,
            bwfTimeRefHigh: 0,
            originationDate: "",
            tapeName:        "",
            ixmlNote:        "",
            ucsCategory:     "",
            ucsSubCategory:  "",
            notes:      "",
            starRating: 0,
            dateAdded:     Date(),
            lastModified:  Date()
        )

        let ext = url.pathExtension.lowercased()

        if ext == "wav" {
            // Single streaming FileHandle pass — reads only header chunks, never the audio data.
            // Avoids mapping/loading potentially gigabyte-sized files into memory.
            let wav = RIFFParser.readWAVMetadata(at: url)
            file.sampleRate = wav.sampleRate
            file.bitDepth   = wav.bitDepth
            file.channels   = wav.channels
            file.duration   = wav.duration

            // Comprehensive BWF/iXML/RIFF-INFO mapping from the chunk blobs the
            // streaming pass already extracted — no second file read.
            if wav.bextData != nil || wav.ixmlData != nil || wav.infoData != nil {
                let meta = BWFParser.parse(bext: wav.bextData, ixml: wav.ixmlData, info: wav.infoData)
                Self.apply(meta, to: &file)
            }
        } else {
            // AIFF / other: AudioToolbox reads only the file header, not audio data
            let meta = AIFFReader.read(url: url)
            file.sampleRate = meta.sampleRate.map { Int($0) }
            file.bitDepth   = meta.bitDepth
            file.channels   = meta.channels
            file.duration   = meta.duration
        }

        try fileRepo.upsert(&file)
    }

    func fetchAllMtimes() throws -> [String: Double] {
        try fileRepo.fetchAllMtimes()
    }

    func fetchFileURLs(inFolder path: String) throws -> [String] {
        try db.read { db in
            try String.fetchAll(db,
                sql: "SELECT file_url FROM audio_files WHERE file_url LIKE ?",
                arguments: ["\(path)/%"])
        }
    }

    func removeFile(at url: URL) async {
        try? fileRepo.delete(fileURL: url.path)
    }

    // MARK: - Watched Folders

    func addWatchedFolder(url: URL, scanner: FolderScanner) throws {
        let bookmark = (try? url.bookmarkData()) ?? Data()
        var folder = WatchedFolder(id: nil, path: url.path,
                                   bookmarkData: bookmark, dateAdded: Date())
        try db.write { db in try folder.upsert(db) }
        scanner.scan(path: url.path)
    }

    func removeWatchedFolder(path: String, scanner: FolderScanner) throws {
        try db.write { db in
            try WatchedFolder.filter(Column("path") == path).deleteAll(db)
            try db.execute(sql: "DELETE FROM audio_files WHERE file_url LIKE ?",
                           arguments: ["\(path)/%"])
        }
    }

    func fetchWatchedFolders() throws -> [WatchedFolder] {
        try db.read { db in try WatchedFolder.fetchAll(db) }
    }

    func updateScannedFileCount(path: String, count: Int) {
        try? db.write { db in
            try db.execute(
                sql: "UPDATE watched_folders SET scanned_file_count = ?, last_scanned = ? WHERE path = ?",
                arguments: [count, Date(), path])
        }
    }

    func rescanFolder(path: String, scanner: FolderScanner) {
        Task.detached(priority: .utility) {
            await scanner.rescan(path: path)
        }
    }

    // MARK: - Helpers

    /// Replaces characters illegal in Pro Tools session filenames with dashes.
    private static func ptSafe(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: ":/\\*?\"<>|"))
         .joined(separator: "-")
    }

    /// Maps parsed BWF metadata into the persisted AudioFile columns.
    private static func apply(_ meta: BWFMetadata, to file: inout AudioFile) {
        // bext
        file.bwfDescription   = ptSafe(meta.description ?? "")
        file.bwfOriginator    = meta.originator ?? ""
        file.bwfOriginatorRef = meta.originatorRef ?? ""
        file.originationDate  = meta.date ?? ""
        file.bwfTime          = meta.time ?? ""
        if let ref = meta.timeReference {
            file.bwfTimeRefLow  = Int64(UInt32(truncatingIfNeeded: ref))
            file.bwfTimeRefHigh = Int64(UInt32(truncatingIfNeeded: ref >> 32))
        }
        file.bwfVersion       = meta.version
        file.bwfUMID          = meta.umid ?? ""
        file.bwfCodingHistory = meta.codingHistory ?? ""
        file.lufs             = meta.loudness ?? file.lufs
        file.loudnessRange    = meta.loudnessRange
        file.maxTruePeak      = meta.maxTruePeak
        file.maxMomentary     = meta.maxMomentary
        file.maxShortTerm     = meta.maxShortTerm
        // iXML
        file.bwfScene           = meta.scene ?? ""
        file.bwfTake            = meta.take ?? ""
        file.tapeName           = meta.tape ?? ""
        file.ixmlNote           = meta.note ?? ""
        file.ixmlCircled        = meta.circled ?? ""
        file.ucsCategory        = meta.category ?? ""
        file.ucsSubCategory     = meta.subCategory ?? ""
        file.ixmlTrackNames     = meta.trackNamesJoined ?? ""
        file.ixmlProject        = meta.project ?? ""
        file.ixmlFileUID        = meta.fileUID ?? ""
        file.ixmlUbits          = meta.ubits ?? ""
        file.ixmlFileSampleRate = meta.fileSampleRate ?? ""
        file.ixmlMasterSpeed    = meta.masterSpeed ?? ""
        file.ixmlTimecodeRate   = meta.timecodeRate ?? ""
        file.ixmlTimecodeFlag   = meta.timecodeFlag ?? ""
        file.ixmlFamilyName     = meta.familyName ?? ""
        file.ixmlLocationName   = meta.locationName ?? ""
        // RIFF INFO
        file.infoTitle      = meta.infoTitle ?? ""
        file.infoArtist     = meta.infoArtist ?? ""
        file.infoComment    = meta.infoComment ?? ""
        file.infoCopyright  = meta.infoCopyright ?? ""
        file.infoGenre      = meta.infoGenre ?? ""
        file.infoCreated    = meta.infoCreated ?? ""
        file.infoSoftware   = meta.infoSoftware ?? ""
        file.infoEngineer   = meta.infoEngineer ?? ""
        file.infoSource     = meta.infoSource ?? ""
        file.infoProduct    = meta.infoProduct ?? ""
        file.infoSubject    = meta.infoSubject ?? ""
        file.infoTechnician = meta.infoTechnician ?? ""
    }
}
