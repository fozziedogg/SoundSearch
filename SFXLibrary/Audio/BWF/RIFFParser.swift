import Foundation

enum RIFFError: Error {
    case notWAV
    case truncated
    case invalidChunk
}

// MARK: - Streaming WAV metadata (no full-file load)

struct WAVMetadata {
    var sampleRate: Int?
    var bitDepth: Int?
    var channels: Int?
    var duration: Double?
    var bextData: Data?
    var ixmlData: Data?
}

struct RIFFChunk {
    let fourCC: String
    let offset: Int     // byte offset of chunk DATA (after the 8-byte header)
    let size: Int       // data size as written in the header
}

struct RIFFParser {
    /// Streams only the header chunks of a WAV file via FileHandle.
    /// Reads fmt (technical metadata), bext, and iXML without loading audio data.
    /// For a 5 GB file this reads only the first few KB instead of mapping everything.
    static func readWAVMetadata(at url: URL) -> WAVMetadata {
        var result = WAVMetadata()
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return result }
        defer { try? handle.close() }

        // RIFF/WAVE header (12 bytes)
        let header = handle.readData(ofLength: 12)
        guard header.count == 12,
              String(bytes: header[0..<4], encoding: .isoLatin1) == "RIFF",
              String(bytes: header[8..<12], encoding: .isoLatin1) == "WAVE"
        else { return result }

        var blockAlign: Int = 0

        while true {
            let chunkHeader = handle.readData(ofLength: 8)
            guard chunkHeader.count == 8 else { break }
            let fourCC = String(bytes: chunkHeader[0..<4], encoding: .isoLatin1) ?? ""
            let size   = Int(chunkHeader.loadLE(UInt32.self, at: 4))
            guard size >= 0 else { break }
            let paddedSize = size + (size & 1)

            if fourCC == "fmt " {
                let fmtData = handle.readData(ofLength: min(size, 40))
                if fmtData.count >= 16 {
                    let ch  = Int(fmtData.loadLE(UInt16.self, at: 2))
                    let sr  = Int(fmtData.loadLE(UInt32.self, at: 4))
                    let ba  = Int(fmtData.loadLE(UInt16.self, at: 12))
                    let bps = Int(fmtData.loadLE(UInt16.self, at: 14))
                    result.sampleRate = sr
                    result.bitDepth   = bps > 0 ? bps : nil
                    result.channels   = ch > 0 ? ch : nil
                    blockAlign        = ba
                }
                // Skip any remaining fmt bytes
                let read = min(size, 40)
                if paddedSize > read {
                    handle.seek(toFileOffset: handle.offsetInFile + UInt64(paddedSize - read))
                }

            } else if fourCC == "data" {
                // Compute duration from data size and format, then stop — don't seek into audio data
                if let sr = result.sampleRate, sr > 0, blockAlign > 0 {
                    result.duration = Double(size) / Double(sr * blockAlign)
                }
                break

            } else if fourCC == "bext" {
                result.bextData = handle.readData(ofLength: size)
                if size & 1 == 1 { handle.seek(toFileOffset: handle.offsetInFile + 1) }

            } else if fourCC == "iXML" {
                result.ixmlData = handle.readData(ofLength: size)
                if size & 1 == 1 { handle.seek(toFileOffset: handle.offsetInFile + 1) }

            } else {
                handle.seek(toFileOffset: handle.offsetInFile + UInt64(paddedSize))
            }
        }
        return result
    }

    /// Parse all top-level chunks from a WAV file's raw Data.
    static func chunks(in data: Data) throws -> [RIFFChunk] {
        guard data.count >= 12 else { throw RIFFError.truncated }
        guard String(bytes: data[0..<4], encoding: .isoLatin1) == "RIFF",
              String(bytes: data[8..<12], encoding: .isoLatin1) == "WAVE"
        else { throw RIFFError.notWAV }

        var result: [RIFFChunk] = []
        var cursor = 12
        while cursor + 8 <= data.count {
            let fourCC = String(bytes: data[cursor..<cursor+4], encoding: .isoLatin1) ?? "????"
            let size   = Int(data.loadLE(UInt32.self, at: cursor + 4))
            result.append(RIFFChunk(fourCC: fourCC, offset: cursor + 8, size: size))
            cursor += 8 + size + (size % 2)  // RIFF pads chunks to even byte boundary
        }
        return result
    }

    /// Returns new file Data with the named chunk replaced (or inserted before "data" if absent).
    static func replacingChunk(fourCC: String,
                                newData: Data,
                                in fileData: Data) throws -> Data {
        let chunks = try Self.chunks(in: fileData)
        var result = fileData

        if let existing = chunks.first(where: { $0.fourCC == fourCC }) {
            // Rebuild: remove old chunk, insert new one at same position
            let chunkStart = existing.offset - 8
            let chunkEnd   = existing.offset + existing.size + (existing.size % 2)
            var header = Data(count: 8)
            header[0..<4] = fourCC.data(using: .isoLatin1)!
            header.storeLE(UInt32(newData.count), at: 4)
            let padded = newData.count % 2 == 1 ? newData + Data([0]) : newData
            result.replaceSubrange(chunkStart..<chunkEnd, with: header + padded)
        } else {
            // Insert before the "data" chunk
            let insertAt: Int
            if let dataChunk = chunks.first(where: { $0.fourCC == "data" }) {
                insertAt = dataChunk.offset - 8
            } else {
                insertAt = result.count
            }
            var header = Data(count: 8)
            header[0..<4] = fourCC.data(using: .isoLatin1)!
            header.storeLE(UInt32(newData.count), at: 4)
            let padded = newData.count % 2 == 1 ? newData + Data([0]) : newData
            result.insert(contentsOf: header + padded, at: insertAt)
        }

        // Update RIFF size field at bytes 4–7
        result.storeLE(UInt32(result.count - 8), at: 4)
        return result
    }
}

// MARK: - Data helpers

extension Data {
    func loadLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value = T.zero
        _ = Swift.withUnsafeMutableBytes(of: &value) { dest in
            copyBytes(to: dest, from: offset..<offset + MemoryLayout<T>.size)
        }
        return T(littleEndian: value)
    }

    mutating func storeLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { src in
            replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: src)
        }
    }
}
