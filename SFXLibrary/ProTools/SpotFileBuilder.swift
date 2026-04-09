import Foundation

struct SpotFileBuilder {
    /// Creates a temporary copy of the audio file with the BEXT TimeReference
    /// set to the given sample offset. The original file is never modified.
    /// - Returns: URL of the temp file (caller is responsible for cleanup, though
    ///   AppDelegate cleans the whole temp dir on next launch).
    static func buildSpotFile(source: URL, sampleOffset: UInt64) throws -> URL {
        let fileData = try Data(contentsOf: source, options: .mappedIfSafe)

        // Parse existing BEXT or create empty one
        let chunks = try RIFFParser.chunks(in: fileData)
        var bext: BEXTChunk
        if let bextChunk = chunks.first(where: { $0.fourCC == "bext" }) {
            let chunkData = fileData.subdata(in: bextChunk.offset..<bextChunk.offset + bextChunk.size)
            bext = (try? BEXTChunk.parse(from: chunkData)) ?? BEXTChunk.empty()
        } else {
            bext = BEXTChunk.empty()
        }

        bext.timeReference = sampleOffset
        let bextData = bext.encode()

        let patched = try RIFFParser.replacingChunk(fourCC: "bext",
                                                    newData: bextData,
                                                    in: fileData)

        // Write to temp directory
        let spotDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SFXLibrarySpot", isDirectory: true)
        try FileManager.default.createDirectory(at: spotDir,
                                                 withIntermediateDirectories: true)
        let destURL = spotDir.appendingPathComponent(source.lastPathComponent)
        try patched.write(to: destURL, options: .atomic)
        return destURL
    }
}
