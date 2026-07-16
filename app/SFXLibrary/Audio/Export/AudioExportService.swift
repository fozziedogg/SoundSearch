import AVFoundation
import Foundation
import os

/// Settings for a single export/convert operation.
struct ExportSettings {
    var format: AudioExportFormat
    var sampleRate: Int?                  // nil = keep source rate
    var bitDepth: Int?                    // nil = keep source depth (16/24/32-float)
    var aacBitrate: Int = 256_000         // AAC only
    var mp3Bitrate: Int = 320             // MP3 only (kbps)
    var region: ClosedRange<Double>?      // nil = whole file; fractions 0…1 (single-file only)
    var preserveMetadata: Bool = true
}

enum ExportError: LocalizedError {
    case emptyInput
    case bufferAllocationFailed
    case converterInitFailed
    case conversionFailed(String)
    case writeFailed(String)
    case mp3EncoderUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyInput:             return "The source file has no audio to export."
        case .bufferAllocationFailed: return "Could not allocate an audio buffer."
        case .converterInitFailed:    return "Could not create an audio converter for this format."
        case .conversionFailed(let m): return "Audio conversion failed: \(m)"
        case .writeFailed(let m):     return "Could not write the exported file: \(m)"
        case .mp3EncoderUnavailable:  return "MP3 export is not available in this build."
        }
    }
}

/// Converts audio files to other formats at high quality using AVAudioConverter
/// (mastering-grade sample-rate conversion + dither) and AVAudioFile. MP3 is
/// handled separately via the LAME wrapper (see the `.mp3` branch).
enum AudioExportService {

    private static let log = Logger(subsystem: "com.mattchan.SoundSearch", category: "export")

    /// Exports `source` to `dest` per `settings`. Overwrites `dest` if it exists.
    static func export(source: URL, to dest: URL, settings: ExportSettings) async throws {
        try await Task.detached(priority: .userInitiated) {
            try runExport(source: source, dest: dest, settings: settings)
        }.value
    }

    // MARK: - Synchronous implementation (off the main actor)

    private static func runExport(source: URL, dest: URL, settings: ExportSettings) throws {
        let src = try AVAudioFile(forReading: source)
        let srcFormat = src.processingFormat            // float32, deinterleaved, source rate
        let srcSR = srcFormat.sampleRate
        let channels = AVAudioChannelCount(srcFormat.channelCount)

        // Region → frame window.
        var startFrame: AVAudioFramePosition = 0
        var readFrames = AVAudioFrameCount(src.length)
        if let region = settings.region {
            startFrame = AVAudioFramePosition(Double(src.length) * region.lowerBound)
            let endFrame = AVAudioFramePosition(Double(src.length) * region.upperBound)
            readFrames = AVAudioFrameCount(max(0, endFrame - startFrame))
        }
        guard readFrames > 0 else { throw ExportError.emptyInput }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: readFrames) else {
            throw ExportError.bufferAllocationFailed
        }
        src.framePosition = startFrame
        try src.read(into: inBuf, frameCount: readFrames)

        // Resolve targets.
        let targetSR = settings.sampleRate ?? Int(srcSR.rounded())
        let sourceBitDepth = Int(src.fileFormat.streamDescription.pointee.mBitsPerChannel)
        let resolvedBitDepth = settings.format.supportsBitDepth
            ? (settings.bitDepth ?? (sourceBitDepth > 0 ? sourceBitDepth : 24))
            : 16
        let commonFmt = settings.format.processingCommonFormat(resolvedBitDepth: resolvedBitDepth)

        guard let outProcFormat = AVAudioFormat(commonFormat: commonFmt,
                                                sampleRate: Double(targetSR),
                                                channels: channels,
                                                interleaved: true) else {
            throw ExportError.converterInitFailed
        }

        // Convert (sample rate + sample type) with mastering SRC and dither.
        let outBuf = try convert(inBuf, from: srcFormat, to: outProcFormat,
                                 srcSR: srcSR, targetSR: targetSR, commonFmt: commonFmt)

        // Ensure the destination directory exists and any stale file is cleared.
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }

        if settings.format == .mp3 {
            try encodeMP3(buffer: outBuf, commonFmt: commonFmt,
                          sampleRate: targetSR, channels: Int(channels),
                          bitrateKbps: settings.mp3Bitrate, dest: dest)
        } else {
            let fileSettings = settings.format.fileSettings(sampleRate: targetSR,
                                                            channels: Int(channels),
                                                            resolvedBitDepth: resolvedBitDepth,
                                                            bitrate: settings.aacBitrate)
            try writeViaAVAudioFile(outBuf, settings: fileSettings,
                                    commonFmt: commonFmt, dest: dest)
        }

        // Re-attach BWF metadata for WAV targets.
        if settings.format.supportsMetadataBWF && settings.preserveMetadata {
            do {
                try ExportMetadataWriter.copyBWFMetadata(
                    from: source, to: dest,
                    sampleRateRatio: Double(targetSR) / srcSR)
            } catch {
                log.error("BWF metadata copy failed: \(String(describing: error))")
            }
        }
    }

    // MARK: - Conversion

    private static func convert(_ inBuf: AVAudioPCMBuffer,
                                from srcFormat: AVAudioFormat,
                                to outFormat: AVAudioFormat,
                                srcSR: Double, targetSR: Int,
                                commonFmt: AVAudioCommonFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: srcFormat, to: outFormat) else {
            throw ExportError.converterInitFailed
        }
        if targetSR != Int(srcSR.rounded()) {
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = .max
        }
        if commonFmt == .pcmFormatInt16 {
            converter.dither = true       // TPDF dither on 16-bit reduction
        }

        let ratio = Double(targetSR) / srcSR
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 8192
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw ExportError.bufferAllocationFailed
        }

        var fed = false
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, inStatus in
            if fed { inStatus.pointee = .endOfStream; return nil }
            fed = true
            inStatus.pointee = .haveData
            return inBuf
        }
        if let convError { throw ExportError.conversionFailed(convError.localizedDescription) }
        guard status != .error else { throw ExportError.conversionFailed("converter returned .error") }
        return outBuf
    }

    // MARK: - Writers

    /// Writes `buffer` to `dest` via AVAudioFile, then closes it (the file flushes
    /// on deallocation when this function returns).
    private static func writeViaAVAudioFile(_ buffer: AVAudioPCMBuffer,
                                            settings: [String: Any],
                                            commonFmt: AVAudioCommonFormat,
                                            dest: URL) throws {
        do {
            let outFile = try AVAudioFile(forWriting: dest, settings: settings,
                                          commonFormat: commonFmt, interleaved: true)
            try outFile.write(from: buffer)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    /// MP3 encoding via the LAME wrapper. Implemented once the SwiftLAME package
    /// is added (see the audio-export plan). Until then this throws so the rest of
    /// the export pipeline can ship and be tested with the native formats.
    private static func encodeMP3(buffer: AVAudioPCMBuffer,
                                  commonFmt: AVAudioCommonFormat,
                                  sampleRate: Int, channels: Int,
                                  bitrateKbps: Int, dest: URL) throws {
        throw ExportError.mp3EncoderUnavailable
    }
}
