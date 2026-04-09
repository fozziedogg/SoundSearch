import Foundation
import AVFoundation
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

    func ingestFile(at url: URL, force: Bool = false) async {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size  = attrs[.size] as? Int64 else { return }

        let mtimeDouble = mtime.timeIntervalSince1970

        // Skip if already in DB and unchanged (unless force rescan)
        if !force,
           let existing = try? fileRepo.fetch(fileURL: url.path),
           existing.mtime == mtimeDouble { return }

        var file = AudioFile(
            id: nil,
            fileURL:    url.path,
            bookmarkData: nil,
            filename:   url.lastPathComponent,
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
            ixmlRaw:    nil,
            notes:      "",
            starRating: 0,
            waveformPeaks: nil,
            dateAdded:     Date(),
            lastModified:  Date()
        )

        // Read technical metadata via AVURLAsset
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            let format = try? await track.load(.formatDescriptions).first
            if let asbd = format.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) {
                file.sampleRate = Int(asbd.mSampleRate)
                file.bitDepth   = Int(asbd.mBitsPerChannel)
                file.channels   = Int(asbd.mChannelsPerFrame)
            }
        }
        if let duration = try? await asset.load(.duration) {
            file.duration = CMTimeGetSeconds(duration)
        }

        // Read BWF/iXML for WAV files
        let ext = url.pathExtension.lowercased()
        if ext == "wav" {
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
               let chunks = try? RIFFParser.chunks(in: data) {
                // BEXT
                if let bextChunk = chunks.first(where: { $0.fourCC == "bext" }) {
                    let chunkData = data.subdata(in: bextChunk.offset..<bextChunk.offset + bextChunk.size)
                    if let bext = try? BEXTChunk.parse(from: chunkData) {
                        file.bwfDescription  = bext.description
                        file.bwfOriginator   = bext.originator
                        file.bwfTimeRefLow   = Int64(bext.timeReferenceLow)
                        file.bwfTimeRefHigh  = Int64(bext.timeReferenceHigh)
                        file.originationDate = bext.originationDate
                    }
                }
                // iXML
                if let ixmlChunk = chunks.first(where: { $0.fourCC == "iXML" }) {
                    let chunkData = data.subdata(in: ixmlChunk.offset..<ixmlChunk.offset + ixmlChunk.size)
                    let fields      = iXMLChunk.parse(from: chunkData)
                    file.bwfScene      = fields.scene          ?? ""
                    file.bwfTake       = fields.take           ?? ""
                    file.tapeName      = fields.tapeName       ?? ""
                    file.ixmlNote      = fields.note           ?? ""
                    file.ucsCategory   = fields.ucsCategory    ?? ""
                    file.ucsSubCategory = fields.ucsSubCategory ?? ""
                    file.ixmlRaw       = String(data: chunkData, encoding: .utf8)
                }
            }
        }

        try? fileRepo.upsert(&file)
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
        scanner.startWatching(path: url.path)
    }

    func removeWatchedFolder(path: String, scanner: FolderScanner) throws {
        scanner.stopWatching(path: path)
        try db.write { db in
            try WatchedFolder.filter(Column("path") == path).deleteAll(db)
        }
    }

    func fetchWatchedFolders() throws -> [WatchedFolder] {
        try db.read { db in try WatchedFolder.fetchAll(db) }
    }

    func rescanFolder(path: String, scanner: FolderScanner) {
        Task.detached(priority: .utility) {
            await scanner.rescan(path: path)
        }
    }
}
