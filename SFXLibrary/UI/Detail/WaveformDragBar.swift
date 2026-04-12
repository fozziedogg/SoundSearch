import SwiftUI
import AVFoundation
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
            .onDrag { makeItemProvider() }
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

    /// If `url`'s filename contains characters illegal in Pro Tools, copies the
    /// file to a temp location with a sanitized name and returns that URL.
    /// Otherwise returns `url` unchanged.
    private static func ptSafeDeliverURL(_ url: URL) -> URL {
        let illegal = CharacterSet(charactersIn: ":/\\*?\"<>|")
        let original = url.lastPathComponent
        let clean = original
            .components(separatedBy: illegal)
            .joined(separator: "-")
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

    // MARK: - Drag item provider

    private func makeItemProvider() -> NSItemProvider {
        let sourceURL    = URL(fileURLWithPath: file.fileURL)
        let selStart     = player.selectionStart
        let selEnd       = player.selectionEnd
        let hasSelection = selStart != nil && selEnd != nil && (selEnd ?? 0) > (selStart ?? 0)

        // Build the file to deliver synchronously (in-process AVAudioFile copy, ~< 50 ms).
        let deliverURL: URL

        if env.dragExportMode == .wholeFile {
            if hasSelection, let s = selStart {
                // Deliver the original file with BEXT patched to the selection timecode.
                // The full file audio is available for trimming in PT.
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
                let desc = file.bwfDescription.trimmingCharacters(in: .whitespaces)
                let baseName = desc.isEmpty
                    ? sourceURL.deletingPathExtension().lastPathComponent
                    : desc
                let safeName = baseName
                    .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " _-")).inverted)
                    .joined(separator: "_")
                print("[Drag] destName=\(safeName)")
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

        // Ensure the delivered filename contains no characters illegal in Pro Tools
        // (colons, slashes, etc.). If the name is already clean this is a no-op.
        let finalURL = WaveformDragBar.ptSafeDeliverURL(deliverURL)
        print("[Drag] delivering → \(finalURL.path)")

        // registerObject(url as NSURL) puts public.file-url on the pasteboard —
        // the type Pro Tools checks for in draggingEntered:.
        let provider = NSItemProvider()
        provider.registerObject(finalURL as NSURL, visibility: .all)
        return provider
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
        let dest = dir.appendingPathComponent("Selection_\(destName).\(sourceURL.pathExtension)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }

        // For WAV: slice raw PCM bytes directly — no re-encoding, exact format preserved.
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

            // Build RIFF/WAVE: fmt chunk verbatim + new data chunk.
            var out = Data()
            out += "RIFF".data(using: .isoLatin1)!
            out += Data(count: 4)                           // RIFF size — filled below
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

        // Fallback for AIFF and non-standard WAV: re-encode via AVAudioFile.
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

    enum ExportError: Error { case emptySelection, bufferAllocationFailed }
}
