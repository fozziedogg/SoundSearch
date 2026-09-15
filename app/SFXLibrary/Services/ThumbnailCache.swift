import Foundation

/// In-memory cache for waveform peaks (NSCache, cleared on memory pressure).
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let mem = NSCache<NSString, NSData>()

    private init() {
        mem.countLimit = 500  // keep up to 500 waveforms in RAM
    }

    private func key(url: String, mtime: Double, width: Int) -> NSString {
        "\(url):\(mtime):\(width)" as NSString
    }

    func get(url: String, mtime: Double, width: Int) -> [[Float]]? {
        let k = key(url: url, mtime: mtime, width: width)
        guard let data = mem.object(forKey: k) as Data? else { return nil }
        let decoded = WaveformGenerator.decode(data: data)
        return decoded.isEmpty ? nil : decoded
    }

    func set(peaks: [[Float]], url: String, mtime: Double, width: Int) {
        let k    = key(url: url, mtime: mtime, width: width)
        let data = WaveformGenerator.encode(peaks: peaks) as NSData
        mem.setObject(data, forKey: k)
    }
}
