import Foundation
import AVFoundation

enum PeakFinder {
    /// Finds the sample with the highest absolute amplitude within the given file fraction range.
    /// Reads at full PCM resolution in 64k-frame chunks to keep memory flat.
    /// - Parameters:
    ///   - url:   Audio file URL.
    ///   - start: Start as a fraction of total file duration (0.0–1.0).
    ///   - end:   End as a fraction of total file duration (0.0–1.0).
    /// - Returns: Sample index from file start, and time offset in seconds from file start.
    static func findPeak(in url: URL,
                         start: Double = 0.0,
                         end:   Double = 1.0) async throws -> (sampleIndex: Int64, offsetSeconds: Double) {
        try await Task.detached(priority: .userInitiated) {
            let file         = try AVAudioFile(forReading: url)
            let length       = file.length
            guard length > 0 else { throw PeakError.emptyFile }

            let startFrame   = AVAudioFramePosition((max(0.0, start) * Double(length)).rounded())
            let endFrame     = AVAudioFramePosition((min(1.0, end)   * Double(length)).rounded())
            let totalFrames  = endFrame - startFrame
            guard totalFrames > 0 else { throw PeakError.emptyRange }

            let channelCount = Int(file.processingFormat.channelCount)
            let chunkSize    = AVAudioFrameCount(min(65_536, AVAudioFrameCount(totalFrames)))

            var peakAmp:   Float = 0
            var peakFrame: Int64 = startFrame
            var consumed:  Int64 = 0

            file.framePosition = startFrame

            while consumed < totalFrames {
                let thisChunk = min(chunkSize, AVAudioFrameCount(totalFrames - consumed))
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: thisChunk)
                else { throw PeakError.bufferAllocationFailed }
                try file.read(into: buf, frameCount: thisChunk)
                let actual = Int(buf.frameLength)
                guard actual > 0 else { break }

                if let data = buf.floatChannelData {
                    for frame in 0..<actual {
                        var maxCh: Float = 0
                        for ch in 0..<channelCount { maxCh = max(maxCh, abs(data[ch][frame])) }
                        if maxCh > peakAmp {
                            peakAmp   = maxCh
                            peakFrame = startFrame + consumed + Int64(frame)
                        }
                    }
                }
                consumed += Int64(actual)
            }

            let offsetSeconds = Double(peakFrame) / file.processingFormat.sampleRate
            return (sampleIndex: peakFrame, offsetSeconds: offsetSeconds)
        }.value
    }

    enum PeakError: LocalizedError {
        case emptyFile, emptyRange, bufferAllocationFailed
        var errorDescription: String? {
            switch self {
            case .emptyFile:              return "Audio file is empty."
            case .emptyRange:             return "Selection range is empty."
            case .bufferAllocationFailed: return "Could not allocate audio buffer for peak detection."
            }
        }
    }
}
