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
        let asset = AVURLAsset(url: url)

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw WaveformError.noAudioTrack }

        // Load format description and duration simultaneously
        async let formatDescs = track.load(.formatDescriptions)
        async let duration     = asset.load(.duration)

        let channelCount: Int
        var nativeSampleRate: Double = 44100
        if let desc = try await formatDescs.first {
            let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
            channelCount     = Int(basicDesc?.pointee.mChannelsPerFrame ?? 1)
            nativeSampleRate = basicDesc?.pointee.mSampleRate ?? 44100
        } else {
            channelCount = 1
        }

        // Compute bucket size from duration so we never need to accumulate all samples
        let totalFrames    = max(1, Int(CMTimeGetSeconds(try await duration) * nativeSampleRate))
        let framesPerBucket = max(1, totalFrames / targetSamples)

        let reader = try AVAssetReader(asset: asset)
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

        // Stream: accumulate peaks per bucket without holding all decoded audio in RAM.
        // Peak memory usage is O(targetSamples × channelCount) instead of O(fileFrames).
        var allChannelPeaks = [[Float]](
            repeating: [Float](repeating: 0, count: targetSamples),
            count: channelCount)
        var bucketIdx      = 0
        var framesInBucket = 0

        while let sampleBuffer = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) {

            let byteCount  = CMBlockBufferGetDataLength(block)
            let frameCount = byteCount / (MemoryLayout<Float>.size * channelCount)
            guard frameCount > 0 else { continue }

            var dataPtr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0,
                                        lengthAtOffsetOut: nil,
                                        totalLengthOut: nil,
                                        dataPointerOut: &dataPtr)
            guard let raw = dataPtr else { continue }
            let floatPtr = UnsafeRawPointer(raw).assumingMemoryBound(to: Float.self)

            var frameOffset = 0
            while frameOffset < frameCount, bucketIdx < targetSamples {
                let chunk = min(framesPerBucket - framesInBucket, frameCount - frameOffset)
                // vDSP_maxmgv with stride = channelCount picks only this channel's samples
                for ch in 0..<channelCount {
                    var chMax: Float = 0
                    vDSP_maxmgv(
                        floatPtr.advanced(by: frameOffset * channelCount + ch),
                        vDSP_Stride(channelCount),
                        &chMax,
                        vDSP_Length(chunk))
                    allChannelPeaks[ch][bucketIdx] = max(allChannelPeaks[ch][bucketIdx], chMax)
                }
                framesInBucket += chunk
                frameOffset    += chunk
                if framesInBucket >= framesPerBucket {
                    bucketIdx      += 1
                    framesInBucket  = 0
                }
            }
            if bucketIdx >= targetSamples { break }
        }

        // Normalise all channels together so relative L/R levels are preserved
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
