import Foundation
import AVFoundation
import Accelerate

enum WaveformError: Error {
    case noAudioTrack
    case readerFailed
}

struct WaveformGenerator {
    /// Generate normalised peak values suitable for display.
    /// - Parameters:
    ///   - url: Audio file URL
    ///   - targetSamples: Number of buckets (= pixel width of the waveform view)
    /// - Returns: Array of Float values in 0...1
    static func peaks(for url: URL, targetSamples: Int) async throws -> [Float] {
        let asset  = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw WaveformError.noAudioTrack }

        let outputSettings: [String: Any] = [
            AVFormatIDKey:             kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey:    32,
            AVLinearPCMIsFloatKey:     true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else { throw WaveformError.readerFailed }

        // Collect all raw float samples
        var rawSamples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            let count  = length / MemoryLayout<Float>.size
            var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0,
                                        lengthAtOffsetOut: nil,
                                        totalLengthOut: nil,
                                        dataPointerOut: &ptr)
            if let p = ptr {
                let floats = UnsafeBufferPointer<Float>(
                    start: UnsafeRawPointer(p).assumingMemoryBound(to: Float.self),
                    count: count)
                rawSamples.append(contentsOf: floats)
            }
        }

        guard !rawSamples.isEmpty else { return [Float](repeating: 0, count: targetSamples) }

        // Downsample: find max absolute value per bucket using Accelerate
        let bucketSize = max(1, rawSamples.count / targetSamples)
        var peaks = [Float](repeating: 0, count: targetSamples)
        rawSamples.withUnsafeBufferPointer { buf in
            for i in 0..<targetSamples {
                let start = i * bucketSize
                let end   = min(start + bucketSize, rawSamples.count)
                guard start < end else { break }
                var maxVal: Float = 0
                vDSP_maxmgv(buf.baseAddress!.advanced(by: start), 1,
                            &maxVal, vDSP_Length(end - start))
                peaks[i] = maxVal
            }
        }

        // Normalise to 0...1
        var maxPeak: Float = 0
        vDSP_maxv(peaks, 1, &maxPeak, vDSP_Length(peaks.count))
        if maxPeak > 0 {
            var scale = 1.0 / maxPeak
            vDSP_vsmul(peaks, 1, &scale, &peaks, 1, vDSP_Length(peaks.count))
        }

        return peaks
    }

    /// Serialise a peaks array to Data (simple Float32 little-endian blob).
    static func encode(peaks: [Float]) -> Data {
        peaks.withUnsafeBytes { Data($0) }
    }

    /// Deserialise peaks from stored Data.
    static func decode(data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
