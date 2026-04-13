import Foundation
import AVFoundation
import Accelerate

enum WaveformError: Error {
    case noAudioTrack
    case readerFailed
}

struct WaveformGenerator {
    /// Generate normalised peak values per channel suitable for display.
    /// - Parameters:
    ///   - url: Audio file URL
    ///   - targetSamples: Number of buckets per channel (= pixel width of the waveform view)
    /// - Returns: Array of channels, each containing Float values in 0...1
    static func peaks(for url: URL, targetSamples: Int) async throws -> [[Float]] {
        let asset  = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw WaveformError.noAudioTrack }

        // Determine channel count from format description
        let formatDescs = try await track.load(.formatDescriptions)
        let channelCount: Int
        if let desc = formatDescs.first {
            let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
            channelCount = Int(basicDesc?.pointee.mChannelsPerFrame ?? 1)
        } else {
            channelCount = 1
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey:      32,
            AVLinearPCMIsFloatKey:       true,
            AVLinearPCMIsBigEndianKey:   false,
            AVLinearPCMIsNonInterleaved: false   // interleaved: L0 R0 L1 R1 …
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else { throw WaveformError.readerFailed }

        // Collect all raw interleaved float samples
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

        guard !rawSamples.isEmpty else {
            return Array(repeating: [Float](repeating: 0, count: targetSamples), count: channelCount)
        }

        // De-interleave: compute peak per bucket per channel using Accelerate with stride
        let frameCount = rawSamples.count / channelCount
        let bucketSize = max(1, frameCount / targetSamples)
        var allChannelPeaks = [[Float]](
            repeating: [Float](repeating: 0, count: targetSamples),
            count: channelCount)

        rawSamples.withUnsafeBufferPointer { buf in
            for ch in 0..<channelCount {
                for i in 0..<targetSamples {
                    let frameStart = i * bucketSize
                    let frameEnd   = min(frameStart + bucketSize, frameCount)
                    guard frameStart < frameEnd else { break }
                    var maxVal: Float = 0
                    // vDSP_maxmgv with stride = channelCount walks only this channel's samples
                    vDSP_maxmgv(
                        buf.baseAddress!.advanced(by: frameStart * channelCount + ch),
                        vDSP_Stride(channelCount),
                        &maxVal,
                        vDSP_Length(frameEnd - frameStart))
                    allChannelPeaks[ch][i] = maxVal
                }
            }
        }

        // Normalise all channels together so relative levels between channels are preserved
        var globalMax: Float = 0
        for ch in 0..<channelCount {
            var chMax: Float = 0
            vDSP_maxv(allChannelPeaks[ch], 1, &chMax, vDSP_Length(targetSamples))
            globalMax = max(globalMax, chMax)
        }
        if globalMax > 0 {
            var scale = 1.0 / globalMax
            for ch in 0..<channelCount {
                vDSP_vsmul(allChannelPeaks[ch], 1, &scale,
                           &allChannelPeaks[ch], 1, vDSP_Length(targetSamples))
            }
        }

        return allChannelPeaks
    }

    // MARK: - Encode / Decode
    // Format: [Int32 channelCount][channel0 Float32 data][channel1 Float32 data]…

    static func encode(peaks: [[Float]]) -> Data {
        var data = Data()
        var count = Int32(peaks.count)
        data.append(Data(bytes: &count, count: 4))
        for channel in peaks {
            data.append(channel.withUnsafeBytes { Data($0) })
        }
        return data
    }

    static func decode(data: Data) -> [[Float]] {
        guard data.count >= 4 else { return [] }
        let channelCount = Int(data.withUnsafeBytes { $0.load(as: Int32.self) })
        guard channelCount > 0 else { return [] }
        let channelDataSize  = (data.count - 4) / channelCount
        var result: [[Float]] = []
        for ch in 0..<channelCount {
            let offset      = 4 + ch * channelDataSize
            let channelData = data[offset..<(offset + channelDataSize)]
            let floats      = channelData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            result.append(floats)
        }
        return result
    }
}
