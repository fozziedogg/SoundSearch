import SwiftUI
import AppKit

struct ProToolsSpotView: View {
    let file: AudioFile
    /// Waveform selection as fractions of file duration. nil = no selection / use whole file.
    let selectionStart: Double?
    let selectionEnd:   Double?

    @Environment(AppEnvironment.self) var env

    @State private var timecode   = "01:00:00:00"
    @State private var frameRate  = FrameRate.fps25
    @State private var preHandle  = 0.5    // seconds
    @State private var postHandle = 0.5    // seconds
    @State private var trackName  = ""

    @State private var isSending  = false
    @State private var sendResult: SendResult? = nil

    enum SendResult {
        case success
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            Text("Pro Tools Spot")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(1)

            // Selection info
            selectionInfoRow

            // Timecode + frame rate
            HStack(spacing: 8) {
                TextField("TC", text: $timecode)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 112)

                Picker("", selection: $frameRate) {
                    ForEach(FrameRate.allCases) { rate in
                        Text(rate.rawValue).tag(rate)
                    }
                }
                .frame(width: 110)
                .labelsHidden()
            }

            // Handle controls + track name
            HStack(spacing: 12) {
                handleStepper(label: "Pre", value: $preHandle)
                handleStepper(label: "Post", value: $postHandle)

                Spacer()

                TextField("Track", text: $trackName)
                    .font(.system(size: 12))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .help("Pro Tools track name (leave blank to let PT choose)")
            }

            // Action buttons + feedback
            HStack(spacing: 8) {
                Button {
                    Task { await sendToPT() }
                } label: {
                    if isSending {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Sending…")
                        }
                    } else {
                        Text("Send to Pro Tools")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || !isTimecodeValid)

                DragToPTButton(file: file, timecode: timecode, frameRate: frameRate)
            }

            if let result = sendResult {
                resultRow(result)
            }
        }
    }

    // MARK: - Sub-views

    private var selectionInfoRow: some View {
        Group {
            if let start = selectionStart, let end = selectionEnd,
               let duration = file.duration {
                let startSec = start * duration
                let endSec   = end   * duration
                HStack(spacing: 6) {
                    Image(systemName: "scissors")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(String(format: "%.3fs – %.3fs  (%.3fs)",
                                startSec, endSec, endSec - startSec))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("No selection — whole file will be used")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func handleStepper(label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 26, alignment: .trailing)
            TextField("", value: value, format: .number.precision(.fractionLength(1...2)))
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
            Text("s")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Stepper("", value: value, in: 0...60, step: 0.5)
                .labelsHidden()
                .frame(width: 36)
        }
    }

    @ViewBuilder
    private func resultRow(_ result: SendResult) -> some View {
        switch result {
        case .success:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Spotted successfully").font(.system(size: 11)).foregroundColor(.green)
            }
        case .failure(let msg):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text(msg).font(.system(size: 11)).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Send

    private func sendToPT() async {
        guard let sampleRate = file.sampleRate else {
            sendResult = .failure("File has no sample rate metadata.")
            return
        }
        isSending  = true
        sendResult = nil

        let duration = file.duration ?? 0
        let request  = PTSLSpotRequest(
            fileURL:        URL(fileURLWithPath: file.fileURL),
            selectionStart: selectionStart.map { $0 * duration },
            selectionEnd:   selectionEnd.map   { $0 * duration },
            preHandle:      preHandle,
            postHandle:     postHandle,
            timecode:       timecode,
            frameRate:      frameRate,
            trackName:      trackName,
            sampleRate:     sampleRate
        )

        do {
            try await env.ptslClient.spot(request)
            sendResult = .success
        } catch {
            sendResult = .failure(error.localizedDescription)
        }
        isSending = false
    }

    // MARK: - Validation

    private var isTimecodeValid: Bool {
        let parts = timecode.replacingOccurrences(of: ";", with: ":")
                            .split(separator: ":")
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
    }
}

// MARK: - Legacy drag button

private struct DragToPTButton: View {
    let file: AudioFile
    let timecode: String
    let frameRate: FrameRate

    var body: some View {
        DragInitiatorViewRepresentable(file: file, timecode: timecode, frameRate: frameRate)
            .frame(width: 120, height: 28)
    }
}

struct DragInitiatorViewRepresentable: NSViewRepresentable {
    let file: AudioFile
    let timecode: String
    let frameRate: FrameRate

    func makeNSView(context: Context) -> DragInitiatorNSView {
        let view = DragInitiatorNSView()
        view.file      = file
        view.timecode  = timecode
        view.frameRate = frameRate
        return view
    }

    func updateNSView(_ nsView: DragInitiatorNSView, context: Context) {
        nsView.file      = file
        nsView.timecode  = timecode
        nsView.frameRate = frameRate
    }
}

final class DragInitiatorNSView: NSView {
    var file:      AudioFile?
    var timecode:  String    = "01:00:00:00"
    var frameRate: FrameRate = .fps25

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        NSColor.controlAccentColor.withAlphaComponent(0.4).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: 5, yRadius: 5)
        border.lineWidth = 1
        border.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.controlAccentColor
        ]
        let str  = "Drag to PT ▸"
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: (bounds.width  - size.width)  / 2,
                              y: (bounds.height - size.height) / 2),
                 withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) { /* arm drag */ }

    override func mouseDragged(with event: NSEvent) {
        guard let file,
              let sampleRate = file.sampleRate,
              let offset = try? TimecodeConverter.sampleOffset(
                  from: timecode, frameRate: frameRate, sampleRate: sampleRate)
        else { return }

        let dragProvider = ProToolsDragProvider(
            sourceURL: URL(fileURLWithPath: file.fileURL),
            sampleOffset: offset)
        let item = NSDraggingItem(pasteboardWriter: dragProvider.makePromiseProvider())
        item.setDraggingFrame(bounds, contents: nil)
        beginDraggingSession(with: [item], event: event, source: self)
    }
}

extension DragInitiatorNSView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                          sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
