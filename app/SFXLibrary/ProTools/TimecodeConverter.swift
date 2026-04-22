import Foundation

enum TCError: Error {
    case badFormat
    case outOfRange
}

enum FrameRate: String, CaseIterable, Identifiable {
    case fps23_976  = "23.976"
    case fps24      = "24"
    case fps25      = "25"
    case fps2997df  = "29.97 DF"
    case fps2997ndf = "29.97 NDF"
    case fps30      = "30"

    var id: String { rawValue }

    /// True clock rate (frames per second)
    var nominalFPS: Double {
        switch self {
        case .fps23_976:           return 24000.0 / 1001.0
        case .fps24:               return 24
        case .fps25:               return 25
        case .fps2997df, .fps2997ndf: return 30000.0 / 1001.0
        case .fps30:               return 30
        }
    }

    /// TC frame count per second (what's printed on the timecode display)
    var tcFPS: Int {
        switch self {
        case .fps23_976: return 24
        case .fps24:     return 24
        case .fps25:     return 25
        case .fps2997df, .fps2997ndf: return 30
        case .fps30:     return 30
        }
    }

    var isDropFrame: Bool { self == .fps2997df }
}

struct TimecodeConverter {
    /// Convert a timecode string (HH:MM:SS:FF or HH:MM:SS;FF for DF) to a sample offset.
    /// sampleRate should be the file's native sample rate (e.g. 48000).
    static func sampleOffset(from tc: String,
                              frameRate: FrameRate,
                              sampleRate: Int) throws -> UInt64 {
        // Accept both ":" and ";" as separators
        let normalised = tc.replacingOccurrences(of: ";", with: ":")
        let parts = normalised.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 4 else { throw TCError.badFormat }
        let (hh, mm, ss, ff) = (parts[0], parts[1], parts[2], parts[3])

        guard mm < 60, ss < 60, ff < frameRate.tcFPS else { throw TCError.outOfRange }

        let totalFrames: Int
        if frameRate.isDropFrame {
            // SMPTE 29.97 DF: drop 2 frames at the start of every minute, except multiples of 10
            let totalMinutes = 60 * hh + mm
            let dropped      = 2 * (totalMinutes - totalMinutes / 10)
            let nominal      = (hh * 3600 + mm * 60 + ss) * 30 + ff
            totalFrames      = nominal - dropped
        } else {
            totalFrames = (hh * 3600 + mm * 60 + ss) * frameRate.tcFPS + ff
        }

        let samplesPerFrame = Double(sampleRate) / frameRate.nominalFPS
        return UInt64((Double(totalFrames) * samplesPerFrame).rounded())
    }

    /// Format a sample offset back to a TC string (for display purposes).
    static func timecodeString(from sampleOffset: UInt64,
                                frameRate: FrameRate,
                                sampleRate: Int) -> String {
        let samplesPerFrame = Double(sampleRate) / frameRate.nominalFPS
        let totalFrames     = Int((Double(sampleOffset) / samplesPerFrame).rounded())
        let fps             = frameRate.tcFPS
        let ff  = totalFrames % fps
        let ss  = (totalFrames / fps) % 60
        let mm  = (totalFrames / fps / 60) % 60
        let hh  = totalFrames / fps / 3600
        let sep = frameRate.isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d\(sep)%02d", hh, mm, ss, ff)
    }
}
