import Foundation
import AudioToolbox

struct AIFFMetadata {
    var duration: Double?
    var sampleRate: Double?
    var bitDepth: Int?
    var channels: Int?
}

struct AIFFReader {
    static func read(url: URL) -> AIFFMetadata {
        var audioFile: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr,
              let af = audioFile else { return AIFFMetadata() }
        defer { AudioFileClose(af) }

        // Read stream format
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFileGetProperty(af, kAudioFilePropertyDataFormat, &size, &asbd)

        // Read packet count to compute duration
        var packetCount: Int64 = 0
        var pcSize = UInt32(MemoryLayout<Int64>.size)
        AudioFileGetProperty(af, kAudioFilePropertyAudioDataPacketCount, &pcSize, &packetCount)

        let duration: Double? = asbd.mSampleRate > 0
            ? Double(packetCount) / asbd.mSampleRate
            : nil

        return AIFFMetadata(
            duration:   duration,
            sampleRate: asbd.mSampleRate > 0 ? asbd.mSampleRate : nil,
            bitDepth:   asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil,
            channels:   asbd.mChannelsPerFrame > 0 ? Int(asbd.mChannelsPerFrame) : nil
        )
    }
}
