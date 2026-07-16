import Foundation

/// Re-attaches broadcast metadata to exported files. For WAV targets this copies
/// the source's `bext` / `iXML` / `LIST-INFO` chunks into the freshly written file
/// (AVAudioFile only writes `fmt`/`data`), scaling the BEXT TimeReference when the
/// sample rate changed. Non-WAV / non-RIFF sources are skipped.
enum ExportMetadataWriter {

    /// - Parameters:
    ///   - source: original file (must be a RIFF/WAVE to carry BWF chunks).
    ///   - dest: freshly written WAV to patch in place.
    ///   - sampleRateRatio: targetSR / sourceSR (1.0 when the rate is unchanged).
    static func copyBWFMetadata(from source: URL, to dest: URL,
                                sampleRateRatio: Double) throws {
        // Only RIFF/WAVE sources carry bext/iXML/LIST.
        guard source.pathExtension.lowercased() == "wav" else { return }

        let meta = RIFFParser.readWAVMetadata(at: source)
        guard meta.bextData != nil || meta.ixmlData != nil || meta.infoData != nil else { return }

        var out = try Data(contentsOf: dest)

        // bext — scale TimeReference if the sample rate changed.
        if let bextData = meta.bextData {
            var bextOut = bextData
            if abs(sampleRateRatio - 1.0) > 0.0001,
               var bext = try? BEXTChunk.parse(from: bextData) {
                let scaled = (Double(bext.timeReference) * sampleRateRatio).rounded()
                bext.timeReference = UInt64(max(0, scaled))
                bextOut = bext.encode()
            }
            out = try RIFFParser.replacingChunk(fourCC: "bext", newData: bextOut, in: out)
        }

        // iXML — copied verbatim (best effort; SR-dependent tags left as authored).
        if let ixmlData = meta.ixmlData {
            out = try RIFFParser.replacingChunk(fourCC: "iXML", newData: ixmlData, in: out)
        }

        // LIST/INFO — copied verbatim (payload already includes the "INFO" form id).
        if let infoData = meta.infoData {
            out = try RIFFParser.replacingChunk(fourCC: "LIST", newData: infoData, in: out)
        }

        try out.write(to: dest, options: .atomic)
    }
}
