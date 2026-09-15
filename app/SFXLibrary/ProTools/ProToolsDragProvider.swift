import AppKit
import UniformTypeIdentifiers

/// Holds source info and acts as the NSFilePromiseProviderDelegate.
/// Use makePromiseProvider() to get the object to pass to NSDraggingItem.
final class ProToolsDragProvider: NSObject, NSFilePromiseProviderDelegate {
    private let sourceURL:    URL
    private let sampleOffset: UInt64

    init(sourceURL: URL, sampleOffset: UInt64) {
        self.sourceURL    = sourceURL
        self.sampleOffset = sampleOffset
        super.init()
    }

    /// Returns an NSFilePromiseProvider ready to attach to a drag item.
    func makePromiseProvider() -> NSFilePromiseProvider {
        let ext  = sourceURL.pathExtension.lowercased()
        let type = (ext == "aiff" || ext == "aif")
            ? UTType.aiff.identifier
            : UTType.wav.identifier
        return NSFilePromiseProvider(fileType: type, delegate: self)
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                              fileNameForType fileType: String) -> String {
        sourceURL.lastPathComponent
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                              writePromiseTo destURL: URL) async throws {
        let spotFile = try SpotFileBuilder.buildSpotFile(source: sourceURL,
                                                         sampleOffset: sampleOffset)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: spotFile, to: destURL)
    }
}
