import Foundation

/// Thin wrapper so Table has a non-optional Identifiable ID.
/// AudioFile.id is Int64? (nil before DB insert); all fetched records have real ids.
struct AudioFileRow: Identifiable {
    let file: AudioFile
    var id: Int64 { file.id ?? 0 }

    // Sort keys for optional numeric fields — nil sorts to bottom (–1 / 0).
    var durationSort:   Double { file.duration  ?? -1 }
    var sampleRateSort: Int    { file.sampleRate ?? 0 }
    var bitDepthSort:   Int    { file.bitDepth   ?? 0 }
    var channelSort:    Int    { file.channels   ?? 0 }
}

// MARK: - Display helpers on AudioFile

extension AudioFile {
    /// Filename without extension.
    var displayName: String {
        URL(fileURLWithPath: fileURL).deletingPathExtension().lastPathComponent
    }

    /// Immediate parent folder — used as the library/collection label.
    var libraryName: String {
        URL(fileURLWithPath: fileURL).deletingLastPathComponent().lastPathComponent
    }

    /// Human-readable channel count.
    var channelLabel: String {
        switch channels {
        case 1:      return "Mono"
        case 2:      return "Stereo"
        case let n?: return "\(n)ch"
        default:     return "—"
        }
    }

    /// Sample rate as a compact string: 48000 → "48k", 44100 → "44.1k".
    var sampleRateLabel: String {
        guard let sr = sampleRate else { return "—" }
        let k = Double(sr) / 1000.0
        return k.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(k))k"
            : String(format: "%.1fk", k)
    }

    /// Bit depth as a plain number string.
    var bitDepthLabel: String {
        guard let bd = bitDepth else { return "—" }
        return "\(bd)"
    }
}
