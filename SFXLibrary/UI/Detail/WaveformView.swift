import SwiftUI

struct WaveformView: View {
    let url:   URL
    let mtime: Double

    /// Selected region as fractions of total file duration (0.0–1.0).
    /// nil = no selection.
    @Binding var selectionStart: Double?
    @Binding var selectionEnd:   Double?

    @EnvironmentObject var player: AudioPlayer
    @State private var peaks: [Float] = []

    // Drag state for building a selection
    @State private var dragStart: Double? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {

                // Waveform bars
                Canvas { ctx, size in
                    guard !peaks.isEmpty else { return }
                    let step = size.width / CGFloat(peaks.count)
                    let midY = size.height / 2
                    var path = Path()
                    for (i, peak) in peaks.enumerated() {
                        let x   = CGFloat(i) * step + step / 2
                        let amp = CGFloat(peak) * (size.height / 2) * 0.9
                        path.move(to:    CGPoint(x: x, y: midY - amp))
                        path.addLine(to: CGPoint(x: x, y: midY + amp))
                    }
                    ctx.stroke(path, with: .color(.accentColor.opacity(0.8)),
                               style: StrokeStyle(lineWidth: max(1, step * 0.6)))
                }
                .background(Color.black.opacity(0.3))
                .cornerRadius(4)

                // Selected region highlight
                if let start = selectionStart, let end = selectionEnd, end > start {
                    let w = geo.size.width
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.25))
                        .frame(width: w * CGFloat(end - start))
                        .offset(x: w * CGFloat(start))

                    // In / out handle lines
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                        .offset(x: w * CGFloat(start))
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                        .offset(x: w * CGFloat(end) - 2)
                }

                // Played portion overlay
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: geo.size.width * player.playPosition)

                // Playhead
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 1.5)
                    .offset(x: geo.size.width * player.playPosition - 0.75)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { val in
                        let w    = geo.size.width
                        let frac = clamp(val.location.x / w)
                        if dragStart == nil {
                            dragStart = clamp(val.startLocation.x / w)
                        }
                        guard let start = dragStart else { return }
                        if frac >= start {
                            selectionStart = start
                            selectionEnd   = frac
                        } else {
                            selectionStart = frac
                            selectionEnd   = start
                        }
                    }
                    .onEnded { val in
                        let w    = geo.size.width
                        let frac = clamp(val.location.x / w)
                        guard let start = dragStart else { return }
                        // Collapse to nothing if the drag was basically a tap
                        let minSelectionPx: CGFloat = 4
                        if abs(val.location.x - val.startLocation.x) < minSelectionPx {
                            selectionStart = nil
                            selectionEnd   = nil
                            player.seek(to: frac)
                        }
                        dragStart = nil
                    }
            )
            .onTapGesture { location in
                // Fallback for single tap with no drag — clears selection, seeks
                selectionStart = nil
                selectionEnd   = nil
                player.seek(to: clamp(location.x / geo.size.width))
            }
            .onAppear { loadPeaks(width: Int(geo.size.width)) }
            .onChange(of: url) { _ in
                selectionStart = nil
                selectionEnd   = nil
                loadPeaks(width: Int(geo.size.width))
            }
        }
    }

    // MARK: - Helpers

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    private func loadPeaks(width: Int) {
        if let cached = ThumbnailCache.shared.get(url: url.path, mtime: mtime, width: width) {
            peaks = cached
            return
        }
        Task.detached(priority: .userInitiated) {
            if let generated = try? await WaveformGenerator.peaks(for: url, targetSamples: width) {
                ThumbnailCache.shared.set(peaks: generated, url: url.path, mtime: mtime, width: width)
                await MainActor.run { peaks = generated }
            }
        }
    }
}
