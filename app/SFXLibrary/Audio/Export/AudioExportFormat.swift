import AVFoundation
import Foundation

/// A user-selectable export target format. Drives the on-disk file settings, the
/// intermediate PCM sample type used during conversion, and which options the
/// export UI should offer.
enum AudioExportFormat: String, CaseIterable, Identifiable {
    case wav
    case aiff
    case flac
    case alac      // Apple Lossless (.m4a)
    case aac       // AAC (.m4a)
    case mp3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wav:  return "WAV (BWF)"
        case .aiff: return "AIFF"
        case .flac: return "FLAC"
        case .alac: return "Apple Lossless"
        case .aac:  return "AAC"
        case .mp3:  return "MP3"
        }
    }

    var fileExtension: String {
        switch self {
        case .wav:  return "wav"
        case .aiff: return "aiff"
        case .flac: return "flac"
        case .alac, .aac: return "m4a"
        case .mp3:  return "mp3"
        }
    }

    var isLossless: Bool {
        switch self {
        case .wav, .aiff, .flac, .alac: return true
        case .aac, .mp3:                return false
        }
    }

    /// PCM/lossless formats let the user pick a target bit depth. Lossy codecs
    /// (AAC/MP3) are defined by bitrate instead.
    var supportsBitDepth: Bool {
        switch self {
        case .wav, .aiff, .flac, .alac: return true
        case .aac, .mp3:                return false
        }
    }

    /// Only WAV can carry the full BWF (bext/iXML/LIST-INFO) chunk set.
    var supportsMetadataBWF: Bool { self == .wav }

    /// Lossy codecs expose a bitrate control.
    var isLossy: Bool { self == .aac || self == .mp3 }

    /// True when the encoder path goes through the external LAME wrapper rather
    /// than AVAudioFile.
    var usesLAME: Bool { self == .mp3 }

    // MARK: - Format construction

    /// The `AVAudioCommonFormat` used for the intermediate (converted) PCM buffer
    /// that gets written to the file. Choosing an integer common format lets the
    /// `AVAudioConverter` apply dither during float→int reduction; float keeps
    /// full precision for 32-bit and for compressed encoders.
    func processingCommonFormat(resolvedBitDepth: Int) -> AVAudioCommonFormat {
        switch self {
        case .aac, .mp3:
            return .pcmFormatFloat32          // encoder consumes float
        case .wav, .aiff, .flac, .alac:
            switch resolvedBitDepth {
            case 16:      return .pcmFormatInt16
            case 24:      return .pcmFormatInt32   // packed to 24-bit on disk by ExtAudioFile
            default:      return .pcmFormatFloat32  // 32-bit float
            }
        }
    }

    /// The on-disk file settings dictionary for `AVAudioFile(forWriting:settings:)`.
    /// `bitDepth` is ignored for lossy codecs; `bitrate` for lossless ones.
    func fileSettings(sampleRate: Int, channels: Int,
                      resolvedBitDepth: Int, bitrate: Int) -> [String: Any] {
        let sr = Double(sampleRate)
        switch self {
        case .wav, .aiff:
            let isFloat = resolvedBitDepth >= 32
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sr,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: resolvedBitDepth,
                AVLinearPCMIsFloatKey: isFloat,
                AVLinearPCMIsBigEndianKey: (self == .aiff),
                AVLinearPCMIsNonInterleaved: false,
            ]
        case .flac:
            return [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: sr,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: min(resolvedBitDepth, 24),  // FLAC ≤ 24-bit
            ]
        case .alac:
            return [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sr,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitDepthHintKey: min(resolvedBitDepth, 32),
            ]
        case .aac:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sr,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitrate,
            ]
        case .mp3:
            // MP3 is not written via AVAudioFile — the LAME path uses a temp WAV.
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sr,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
    }
}
