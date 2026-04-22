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

            if let bextData = wav.bextData,
               let bext = try? BEXTChunk.parse(from: bextData) {
                file.bwfDescription  = Self.ptSafe(bext.description)
                file.bwfOriginator   = bext.originator
                file.bwfTimeRefLow   = Int64(bext.timeReferenceLow)
                file.bwfTimeRefHigh  = Int64(bext.timeReferenceHigh)
                file.originationDate = bext.originationDate
            }
            if let ixmlData = wav.ixmlData {
                let fields = iXMLChunk.parse(from: ixmlData)
                file.bwfScene       = fields.scene           ?? ""
                file.bwfTake        = fields.take            ?? ""
                file.tapeName       = fields.tapeName        ?? ""
                file.ixmlNote       = fields.note            ?? ""
                file.ucsCategory    = fields.ucsCategory     ?? ""
                file.ucsSubCategory = fields.ucsSubCategory  ?? ""
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
}
