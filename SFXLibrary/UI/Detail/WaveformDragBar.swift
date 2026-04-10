import SwiftUI
import AppKit
import AVFoundation

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

    /// Absorb mouseDown so the event sequence is owned by this view,
    /// not forwarded to a scroll view ancestor.
    override func mouseDown(with event: NSEvent) { }

    override func mouseDragged(with event: NSEvent) {
        guard let coordinator,
              let file   = coordinator.file,
              let player = coordinator.player else { return }

        let sourceURL = URL(fileURLWithPath: file.fileURL)
        let dragURL: URL
        if let s = player.selectionStart, let e = player.selectionEnd, e > s,
           let tmp = try? Self.exportSelection(from: sourceURL, start: s, end: e) {
            dragURL = tmp
        } else {
            dragURL = sourceURL
        }

        // Write both the legacy type Pro Tools checks on drag-enter and the
        // modern file-url type for other Cocoa receivers.
        let item = NSPasteboardItem()
        item.setPropertyList([dragURL.path],
                             forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        item.setString(dragURL.absoluteString, forType: .fileURL)

        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let icon = NSWorkspace.shared.icon(forFile: dragURL.path)
        draggingItem.setDraggingFrame(
            NSRect(origin: .zero, size: NSSize(width: 32, height: 32)),
            contents: icon
        )

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    // MARK: Selection export

    private static func exportSelection(from sourceURL: URL,
                                        start: Double,
                                        end: Double) throws -> URL {
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

        let dragDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SFXLibraryDrag", isDirectory: true)
        try FileManager.default.createDirectory(at: dragDir, withIntermediateDirectories: true)
        let dest = dragDir.appendingPathComponent("Selection_" + sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        let out = try AVAudioFile(forWriting: dest, settings: src.fileFormat.settings)
        try out.write(from: buffer)
        return dest
    }

    enum ExportError: Error { case emptySelection, bufferAllocationFailed }
}
