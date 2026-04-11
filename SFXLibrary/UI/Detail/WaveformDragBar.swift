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
                exported = try DragBarHelper.exportSelection(from: sourceURL, start: s, end: e)
            } catch {
                print("[Drag] exportSelection failed for \(sourceURL.lastPathComponent): \(error)")
                exported = nil
            }

            if let exported {
                let timeRef = DragBarHelper.selectionTimeReference(file: file, selectionStart: s)
                if let ref = timeRef,
                   let patched = try? SpotFileBuilder.buildSpotFile(source: exported,
                                                                     sampleOffset: ref) {
                    deliverURL = patched
                } else {
                    deliverURL = exported
                }
            } else {
                deliverURL = sourceURL
            }
        } else {
            deliverURL = sourceURL
        }

        // registerObject(url as NSURL) puts public.file-url on the pasteboard —
        // the type Pro Tools checks for in draggingEntered:.
        let provider = NSItemProvider()
        provider.registerObject(deliverURL as NSURL, visibility: .all)
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

    static func exportSelection(from sourceURL: URL, start: Double, end: Double) throws -> URL {
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

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SFXLibraryDrag", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("Selection_" + sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        // Strip AVLinearPCMIsBigEndianKey so AVAudioFile infers byte order from the
        // file extension (AIFF = big-endian, WAV = little-endian). Passing the key
        // explicitly from fileFormat.settings can cause write failures on AIFF files.
        // Force interleaved output — processingFormat is non-interleaved but AVAudioFile
        // converts automatically; a non-interleaved container setting can cause failures.
        var writeSettings = src.fileFormat.settings
        writeSettings[AVLinearPCMIsBigEndianKey] = nil
        writeSettings[AVLinearPCMIsNonInterleaved] = false
        let out = try AVAudioFile(forWriting: dest, settings: writeSettings)
        try out.write(from: buffer)
        return dest
    }

    enum ExportError: Error { case emptySelection, bufferAllocationFailed }
}
