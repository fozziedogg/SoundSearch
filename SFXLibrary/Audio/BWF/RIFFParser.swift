import Foundation

enum RIFFError: Error {
    case notWAV
    case truncated
    case invalidChunk
}

struct RIFFChunk {
    let fourCC: String
    let offset: Int     // byte offset of chunk DATA (after the 8-byte header)
    let size: Int       // data size as written in the header
}

struct RIFFParser {
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
