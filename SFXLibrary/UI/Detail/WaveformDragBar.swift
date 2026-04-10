import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - SwiftUI wrapper

struct WaveformDragBar: NSViewRepresentable {
    let file: AudioFile
    @EnvironmentObject var player: AudioPlayer

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DragBarNSView {
        let v = DragBarNSView()
        v.coordinator = context.coordinator
        return v
    }

    func updateNSView(_ nsView: DragBarNSView, context: Context) {
        context.coordinator.file   = file
        context.coordinator.player = player
        nsView.label = labelText
    }

    // MARK: - Label

    private var labelText: String {
        if hasSelection, let s = player.selectionStart, let e = player.selectionEnd {
            let dur = (e - s) * player.duration
            return "⠿  Drag to PT Timeline  •  Selection  \(fmt(s * player.duration)) – \(fmt(e * player.duration))  (\(fmt(dur)))"
        }
        return player.duration > 0
            ? "⠿  Drag to PT Timeline  •  Full file  (\(fmt(player.duration)))"
            : "⠿  Drag to PT Timeline"
    }

    private func fmt(_ t: Double) -> String { String(format: "%.3fs", t) }

    private var hasSelection: Bool {
        guard let s = player.selectionStart, let e = player.selectionEnd else { return false }
        return e > s
    }

    // MARK: - Coordinator

    final class Coordinator {
        var file:   AudioFile?
        var player: AudioPlayer?
    }
}

// MARK: - NSView

final class DragBarNSView: NSView, NSDraggingSource {

    var label: String = "Drag to PT Timeline" {
        didSet { needsDisplay = true }
    }
    weak var coordinator: WaveformDragBar.Coordinator?

    /// Strong ref — NSFilePromiseProvider holds its delegate weakly.
    private var activeDragProvider: WaveformSelectionDragProvider?

    // MARK: Drawing

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.controlAccentColor
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        let y = (bounds.height - size.height) / 2
        str.draw(at: NSPoint(x: 8, y: y))
    }

    // MARK: Mouse events

    override func mouseDown(with event: NSEvent) { }

    override func mouseDragged(with event: NSEvent) {
        guard let coordinator,
              let file   = coordinator.file,
              let player = coordinator.player else { return }

        let sourceURL    = URL(fileURLWithPath: file.fileURL)
        let selStart     = player.selectionStart
        let selEnd       = player.selectionEnd
        let hasSelection = selStart != nil && selEnd != nil && (selEnd ?? 0) > (selStart ?? 0)

        let timeRef: UInt64? = hasSelection
            ? WaveformSelectionDragProvider.selectionTimeReference(file: file,
                                                                    selectionStart: selStart ?? 0)
            : nil

        let provider = WaveformSelectionDragProvider(
            sourceURL:      sourceURL,
            selectionStart: hasSelection ? selStart : nil,
            selectionEnd:   hasSelection ? selEnd   : nil,
            timeReference:  timeRef
        )
        activeDragProvider = provider

        // Mirror DragInitiatorNSView exactly: promise provider + bounds frame + nil contents.
        // NSFilePromiseProvider gives the system a typed file promise; the actual file is
        // written at drop time so we never block the main thread in mouseDragged.
        let item = NSDraggingItem(pasteboardWriter: provider.makePromiseProvider())
        item.setDraggingFrame(bounds, contents: nil)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        activeDragProvider = nil
    }
}

// MARK: - File promise provider

final class WaveformSelectionDragProvider: NSObject, NSFilePromiseProviderDelegate {

    private let sourceURL:      URL
    private let selectionStart: Double?
    private let selectionEnd:   Double?
    private let timeReference:  UInt64?

    init(sourceURL: URL, selectionStart: Double?, selectionEnd: Double?, timeReference: UInt64?) {
        self.sourceURL      = sourceURL
        self.selectionStart = selectionStart
        self.selectionEnd   = selectionEnd
        self.timeReference  = timeReference
        super.init()
    }

    func makePromiseProvider() -> NSFilePromiseProvider {
        let ext  = sourceURL.pathExtension.lowercased()
        let type = (ext == "aiff" || ext == "aif") ? UTType.aiff.identifier : UTType.wav.identifier
        return NSFilePromiseProvider(fileType: type, delegate: self)
    }

    // MARK: NSFilePromiseProviderDelegate

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                              fileNameForType fileType: String) -> String {
        selectionStart != nil
            ? "Selection_" + sourceURL.lastPathComponent
            : sourceURL.lastPathComponent
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                              writePromiseTo destURL: URL) async throws {
        let fileURL: URL

        if let s = selectionStart, let e = selectionEnd, e > s {
            let exported = try Self.exportSelection(from: sourceURL, start: s, end: e)
            if let ref = timeReference,
               let patched = try? SpotFileBuilder.buildSpotFile(source: exported, sampleOffset: ref) {
                fileURL = patched
            } else {
                fileURL = exported
            }
        } else {
            fileURL = sourceURL
        }

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: fileURL, to: destURL)
    }

    // MARK: Helpers

    static func selectionTimeReference(file: AudioFile, selectionStart: Double) -> UInt64? {
        let refLow  = UInt32(truncatingIfNeeded: file.bwfTimeRefLow)
        let refHigh = UInt32(truncatingIfNeeded: file.bwfTimeRefHigh)
        let baseRef = (UInt64(refHigh) << 32) | UInt64(refLow)
        guard baseRef > 0, let sr = file.sampleRate, let dur = file.duration else { return nil }
        let startSamples = UInt64(max(0.0, selectionStart * Double(sr) * dur))
        return baseRef + startSamples
    }

    private static func exportSelection(from sourceURL: URL, start: Double, end: Double) throws -> URL {
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
        let out = try AVAudioFile(forWriting: dest, settings: src.fileFormat.settings)
        try out.write(from: buffer)
        return dest
    }

    enum ExportError: Error { case emptySelection, bufferAllocationFailed }
}
