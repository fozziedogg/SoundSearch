import SwiftUI
import AVFoundation
import Accelerate
import UniformTypeIdentifiers

// MARK: - Export mode

enum DragExportMode: Int, CaseIterable {
    case selectionOnly = 0
    case wholeFile     = 1

    var label: String {
        switch self {
        case .selectionOnly: return "Selection only"
        case .wholeFile:     return "Whole file"
        }
    }
}

// MARK: - View

struct WaveformDragBar: View {
    let file: AudioFile
    @EnvironmentObject var player: AudioPlayer
    @Environment(AppEnvironment.self) var env

    var body: some View {
        dragBarShape
            .overlay(
                DragHandlerView(
                    computeURL: { computeDeliveryURL() },
                    onDragStarted: { player.stop() },
                    onCompleted: { _ in
                        env.addToActiveProject(fileURL: file.fileURL)
                    }
                )
            )
    }

    // MARK: - Appearance

    private var dragBarShape: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.07))
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
            Text(labelText)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
                .padding(.leading, 8)
        }
    }

    private var labelText: String {
        switch env.dragExportMode {
        case .wholeFile:
            if hasSelection, let s = player.selectionStart {
                return "⠿  Drag to PT Timeline  •  Full file, spot at \(fmt(s * player.duration))"
            }
            return player.duration > 0
                ? "⠿  Drag to PT Timeline  •  Full file  (\(fmt(player.duration)))"
                : "⠿  Drag to PT Timeline"
        case .selectionOnly:
            if hasSelection, let s = player.selectionStart, let e = player.selectionEnd {
                let dur = (e - s) * player.duration
                return "⠿  Drag to PT Timeline  •  Selection  \(fmt(s * player.duration)) – \(fmt(e * player.duration))  (\(fmt(dur)))"
            }
            return player.duration > 0
                ? "⠿  Drag to PT Timeline  •  Full file  (\(fmt(player.duration)))"
                : "⠿  Drag to PT Timeline"
        }
    }

    private var hasSelection: Bool {
        guard let s = player.selectionStart, let e = player.selectionEnd else { return false }
        return e > s
    }

    private func fmt(_ t: Double) -> String { String(format: "%.3fs", t) }

    // MARK: - Drag URL computation

    func computeDeliveryURL() -> URL {
        let sourceURL    = URL(fileURLWithPath: file.fileURL)
        let selStart     = player.selectionStart
        let selEnd       = player.selectionEnd
        let hasSelection = selStart != nil && selEnd != nil && (selEnd ?? 0) > (selStart ?? 0)

        let deliverURL: URL

        if env.dragExportMode == .wholeFile {
            if hasSelection, let s = selStart {
                let timeRef = DragBarHelper.selectionTimeReference(file: file, selectionStart: s)
                if let ref = timeRef,
                   let patched = try? SpotFileBuilder.buildSpotFile(source: sourceURL,
                                                                     sampleOffset: ref) {
                    deliverURL = patched
                } else {
                    deliverURL = sourceURL
                }
            } else {
                deliverURL = sourceURL
            }
        } else if !hasSelection {
            deliverURL = sourceURL
        } else if let s = selStart, let e = selEnd {
            print("[Drag] exporting \(sourceURL.lastPathComponent) sel=\(String(format:"%.3f",s))–\(String(format:"%.3f",e))")
            let exported: URL?
            do {
                let safeName = sourceURL.deletingPathExtension().lastPathComponent
                    .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " _-")).inverted)
                    .joined(separator: "_")
                exported = try DragBarHelper.exportSelection(from: sourceURL, start: s, end: e,
                                                             destName: safeName)
                if let exported {
                    let size = (try? FileManager.default.attributesOfItem(atPath: exported.path))?[.size] as? Int64 ?? -1
                    print("[Drag] exported OK → \(exported.path) (\(size) bytes)")
                }
            } catch {
                print("[Drag] exportSelection failed: \(error)")
                exported = nil
            }

            if let exported {
                let timeRef = DragBarHelper.selectionTimeReference(file: file, selectionStart: s)
                if let ref = timeRef,
                   let patched = try? SpotFileBuilder.buildSpotFile(source: exported,
                                                                     sampleOffset: ref) {
                    print("[Drag] BEXT patched → \(patched.path)")
                    deliverURL = patched
                } else {
                    print("[Drag] no BEXT patch, delivering exported directly")
                    deliverURL = exported
                }
            } else {
                deliverURL = sourceURL
            }
        } else {
            deliverURL = sourceURL
        }

        // Sanitise filename for Pro Tools (no colons, slashes, etc.)
        let sanitised = ptSafeURL(deliverURL)

        // Bake preview volume into the delivered file when the setting is enabled.
        let gain = player.volume
        if env.commitVolumeOnExport, abs(gain - 1.0) > 0.001,
           let gained = try? DragBarHelper.applyGain(to: sanitised, gain: gain) {
            print("[Drag] gain \(String(format: "%.2f", gain))× applied → \(gained.path)")
            return gained
        }

        print("[Drag] delivering → \(sanitised.path)")
        return sanitised
    }

    /// Copies the file to a temp location with a PT-legal filename if needed.
    private func ptSafeURL(_ url: URL) -> URL {
        let illegal = CharacterSet(charactersIn: ":/\\*?\"<>|")
        let original = url.lastPathComponent
        let clean = original.components(separatedBy: illegal).joined(separator: "-")
        guard clean != original else { return url }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SFXLibraryDeliver", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir,
                                                        withIntermediateDirectories: true)) != nil
        else { return url }

        let dest = dir.appendingPathComponent(clean)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return url }
        return dest
    }
}

// MARK: - File helpers

enum DragBarHelper {

    static func selectionTimeReference(file: AudioFile, selectionStart: Double) -> UInt64? {
        let refLow  = UInt32(truncatingIfNeeded: file.bwfTimeRefLow)
        let refHigh = UInt32(truncatingIfNeeded: file.bwfTimeRefHigh)
        let baseRef = (UInt64(refHigh) << 32) | UInt64(refLow)
        guard baseRef > 0, let sr = file.sampleRate, let dur = file.duration else { return nil }
        let startSamples = UInt64(max(0.0, selectionStart * Double(sr) * dur))
        return baseRef + startSamples
    }

    static func exportSelection(from sourceURL: URL, start: Double, end: Double,
                                destName: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SFXLibraryDrag", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(destName).\(sourceURL.pathExtension)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }

        // WAV fast path: slice raw PCM, preserving exact format.
        if sourceURL.pathExtension.lowercased() == "wav",
           let fileData  = try? Data(contentsOf: sourceURL, options: .mappedIfSafe),
           let chunks    = try? RIFFParser.chunks(in: fileData),
           let fmtChunk  = chunks.first(where: { $0.fourCC == "fmt " }),
           let dataChunk = chunks.first(where: { $0.fourCC == "data" }),
           fmtChunk.size >= 16 {

            let blockAlign  = Int(fileData.loadLE(UInt16.self, at: fmtChunk.offset + 12))
            guard blockAlign > 0 else { throw ExportError.emptySelection }
            let totalFrames = dataChunk.size / blockAlign
            let startFrame  = Int(start * Double(totalFrames))
            let endFrame    = Int(end   * Double(totalFrames))
            guard endFrame > startFrame else { throw ExportError.emptySelection }

            let startByte = dataChunk.offset + startFrame * blockAlign
            let endByte   = dataChunk.offset + endFrame   * blockAlign
            guard endByte <= fileData.count else { throw ExportError.emptySelection }
            let sliced = fileData.subdata(in: startByte..<endByte)

            var out = Data()
            out += "RIFF".data(using: .isoLatin1)!
            out += Data(count: 4)                           // filled below
            out += "WAVE".data(using: .isoLatin1)!
            let fmtEnd = fmtChunk.offset + fmtChunk.size + (fmtChunk.size % 2)
            out += fileData.subdata(in: (fmtChunk.offset - 8)..<fmtEnd)
            out += "data".data(using: .isoLatin1)!
            var dataLen = UInt32(sliced.count).littleEndian
            out += Swift.withUnsafeBytes(of: &dataLen) { Data($0) }
            out += sliced
            if sliced.count % 2 == 1 { out += Data([0]) }
            out.storeLE(UInt32(out.count - 8), at: 4)

            try out.write(to: dest, options: .atomic)
            return dest
        }

        // Fallback: re-encode via AVAudioFile (AIFF and non-standard WAV).
        let src        = try AVAudioFile(forReading: sourceURL)
        let startFrame = AVAudioFramePosition(start * Double(src.length))
        let endFrame   = AVAudioFramePosition(end   * Double(src.length))
        let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard frameCount > 0 else { throw ExportError.emptySelection }
        src.framePosition = startFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: src.processingFormat,
                                            frameCapacity: frameCount)
        else { throw ExportError.bufferAllocationFailed }
        try src.read(into: buffer, frameCount: frameCount)
        let fmt = src.fileFormat
        let writeSettings: [String: Any] = [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVSampleRateKey:             fmt.sampleRate,
            AVNumberOfChannelsKey:       fmt.channelCount,
            AVLinearPCMBitDepthKey:      fmt.settings[AVLinearPCMBitDepthKey] ?? 24,
            AVLinearPCMIsFloatKey:       fmt.settings[AVLinearPCMIsFloatKey]  ?? false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outFile = try AVAudioFile(forWriting: dest, settings: writeSettings)
        try outFile.write(from: buffer)
        return dest
    }

    /// Re-encodes `sourceURL` to a temp file with every sample scaled by `gain`.
    /// Returns `sourceURL` unchanged if gain is within 0.1% of unity.
    static func applyGain(to sourceURL: URL, gain: Float) throws -> URL {
        guard abs(gain - 1.0) > 0.001 else { return sourceURL }

        let src = try AVAudioFile(forReading: sourceURL)
        let frameCount = AVAudioFrameCount(src.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: src.processingFormat,
                                            frameCapacity: frameCount)
        else { throw ExportError.bufferAllocationFailed }
        try src.read(into: buffer)

        // Scale all channels using vDSP (in-place).
        if let floatData = buffer.floatChannelData {
            var g = gain
            for ch in 0..<Int(buffer.format.channelCount) {
                vDSP_vsmul(floatData[ch], 1, &g, floatData[ch], 1,
                           vDSP_Length(buffer.frameLength))
            }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SFXLibraryGain", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }

        let fmt = src.fileFormat
        let writeSettings: [String: Any] = [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVSampleRateKey:             fmt.sampleRate,
            AVNumberOfChannelsKey:       fmt.channelCount,
            AVLinearPCMBitDepthKey:      fmt.settings[AVLinearPCMBitDepthKey] ?? 24,
            AVLinearPCMIsFloatKey:       fmt.settings[AVLinearPCMIsFloatKey]  ?? false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outFile = try AVAudioFile(forWriting: dest, settings: writeSettings)
        try outFile.write(from: buffer)
        return dest
    }

    enum ExportError: Error { case emptySelection, bufferAllocationFailed }
}

// MARK: - Drag handler NSViewRepresentable

import AppKit

/// Transparent NSView overlay that initiates a drag and reports the completed NSDragOperation.
struct DragHandlerView: NSViewRepresentable {
    let computeURL:    () -> URL
    let onDragStarted: () -> Void
    let onCompleted:   (NSDragOperation) -> Void

    func makeNSView(context: Context) -> _DragHandlerNSView {
        _DragHandlerNSView(computeURL: computeURL, onDragStarted: onDragStarted, onCompleted: onCompleted)
    }

    func updateNSView(_ nsView: _DragHandlerNSView, context: Context) {
        nsView.computeURL    = computeURL
        nsView.onDragStarted = onDragStarted
        nsView.onCompleted   = onCompleted
    }
}

final class _DragHandlerNSView: NSView, NSDraggingSource {
    var computeURL:    () -> URL
    var onDragStarted: () -> Void
    var onCompleted:   (NSDragOperation) -> Void

    init(computeURL: @escaping () -> URL,
         onDragStarted: @escaping () -> Void,
         onCompleted: @escaping (NSDragOperation) -> Void) {
        self.computeURL    = computeURL
        self.onDragStarted = onDragStarted
        self.onCompleted   = onCompleted
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // Accept mouse-down so we can track drag from this view.
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onDragStarted()
        let url  = computeURL()
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let imgBounds = NSRect(origin: .zero, size: NSSize(width: 48, height: 24))
        item.setDraggingFrame(imgBounds, contents: dragImage())

        beginDraggingSession(with: [item], event: event, source: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        DispatchQueue.main.async { [weak self] in self?.onCompleted(operation) }
    }

    // MARK: Private

    private func dragImage() -> NSImage {
        let size  = NSSize(width: 48, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.controlAccentColor.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 4, yRadius: 4).fill()
        image.unlockFocus()
        return image
    }
}
