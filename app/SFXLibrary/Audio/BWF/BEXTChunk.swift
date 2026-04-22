import Foundation

/// Represents the BWF Broadcast Extension (BEXT) chunk.
/// Fixed 602-byte header followed by a variable-length CodingHistory string.
struct BEXTChunk {
    var description:     String   // 256 bytes, null-padded
    var originator:      String   // 32 bytes
    var originatorRef:   String   // 32 bytes
    var originationDate: String   // 10 bytes "YYYY-MM-DD"
    var originationTime: String   // 8  bytes "HH:MM:SS"
    var timeReferenceLow:  UInt32 // low  32 bits of 64-bit sample offset from midnight
    var timeReferenceHigh: UInt32 // high 32 bits
    var version:         UInt16   // BWF version (0, 1, or 2)
    var umid:            Data     // 64 bytes SMPTE UMID
    var loudnessValue:   Int16    // version 2+, in 0.01 LU
    var loudnessRange:   Int16
    var maxTruePeak:     Int16
    var maxMomentaryLoudness: Int16
    var maxShortTermLoudness: Int16
    var codingHistory:   String   // variable, ASCII

    /// Combined 64-bit sample count from midnight.
    var timeReference: UInt64 {
        get { (UInt64(timeReferenceHigh) << 32) | UInt64(timeReferenceLow) }
        set {
            timeReferenceLow  = UInt32(newValue & 0xFFFF_FFFF)
            timeReferenceHigh = UInt32(newValue >> 32)
        }
    }

    static func empty() -> BEXTChunk {
        BEXTChunk(
            description: "", originator: "", originatorRef: "",
            originationDate: "", originationTime: "",
            timeReferenceLow: 0, timeReferenceHigh: 0,
            version: 2, umid: Data(count: 64),
            loudnessValue: 0x7FFF, loudnessRange: 0x7FFF,
            maxTruePeak: 0x7FFF, maxMomentaryLoudness: 0x7FFF,
            maxShortTermLoudness: 0x7FFF,
            codingHistory: ""
        )
    }

    static func parse(from data: Data) throws -> BEXTChunk {
        guard data.count >= 602 else {
            throw RIFFError.truncated
        }

        func str(_ range: Range<Int>) -> String {
            let bytes = data[range]
            let s = String(bytes: bytes, encoding: .isoLatin1) ?? ""
            return s.trimmingCharacters(in: CharacterSet(["\0"]))
        }

        let timeRefLow  = data.loadLE(UInt32.self, at: 256 + 32 + 32 + 10 + 8)
        let timeRefHigh = data.loadLE(UInt32.self, at: 256 + 32 + 32 + 10 + 8 + 4)
        let version     = data.loadLE(UInt16.self, at: 256 + 32 + 32 + 10 + 8 + 8)

        let umidStart = 256 + 32 + 32 + 10 + 8 + 8 + 2
        let umid = data.subdata(in: umidStart..<umidStart+64)

        // Loudness fields (version 2, at offset 338)
        let loudnessValue        = data.loadLE(Int16.self, at: 338)
        let loudnessRange        = data.loadLE(Int16.self, at: 340)
        let maxTruePeak          = data.loadLE(Int16.self, at: 342)
        let maxMomentary         = data.loadLE(Int16.self, at: 344)
        let maxShortTerm         = data.loadLE(Int16.self, at: 346)

        // CodingHistory starts at 602, null-terminated ASCII
        let codingHistory: String
        if data.count > 602 {
            let chBytes = data[602...]
            codingHistory = String(bytes: chBytes, encoding: .isoLatin1)?
                .trimmingCharacters(in: CharacterSet(["\0"])) ?? ""
        } else {
            codingHistory = ""
        }

        return BEXTChunk(
            description:     str(0..<256),
            originator:      str(256..<288),
            originatorRef:   str(288..<320),
            originationDate: str(320..<330),
            originationTime: str(330..<338),
            timeReferenceLow:  timeRefLow,
            timeReferenceHigh: timeRefHigh,
            version:           version,
            umid:              umid,
            loudnessValue:     loudnessValue,
            loudnessRange:     loudnessRange,
            maxTruePeak:       maxTruePeak,
            maxMomentaryLoudness: maxMomentary,
            maxShortTermLoudness: maxShortTerm,
            codingHistory:     codingHistory
        )
    }

    func encode() -> Data {
        var data = Data(count: 602)

        func write(_ string: String, at offset: Int, length: Int) {
            let bytes = Array((string + String(repeating: "\0", count: length))
                .prefix(length).utf8.map { $0 })
            data.replaceSubrange(offset..<offset+length, with: bytes.prefix(length))
        }

        write(description,     at: 0,   length: 256)
        write(originator,      at: 256, length: 32)
        write(originatorRef,   at: 288, length: 32)
        write(originationDate, at: 320, length: 10)
        write(originationTime, at: 330, length: 8)
        data.storeLE(timeReferenceLow,  at: 338)
        data.storeLE(timeReferenceHigh, at: 342)
        data.storeLE(version,           at: 346)
        data.replaceSubrange(348..<412, with: umid.prefix(64))
        data.storeLE(loudnessValue,        at: 412)
        data.storeLE(loudnessRange,        at: 414)
        data.storeLE(maxTruePeak,          at: 416)
        data.storeLE(maxMomentaryLoudness, at: 418)
        data.storeLE(maxShortTermLoudness, at: 420)
        // reserved bytes 422–601 remain zero

        if !codingHistory.isEmpty {
            let chData = (codingHistory + "\0").data(using: .isoLatin1) ?? Data([0])
            data.append(chData)
        }

        return data
    }
}
