import SwiftUI
import AppKit

// MARK: - Waveform view

struct WaveformView: View {
    let url:         URL
    let mtime:       Double
    let playOnClick: Bool
    var waveColor:   Color = .accentColor

    private let waveBackground = Color(white: 0.07)

    @EnvironmentObject var player: AudioPlayer

    // Waveform data — one sub-array per channel
    @State private var peaks: [[Float]] = []

    // Zoom state
    @State private var zoomLevel:    Double = 1.0   // 1.0 = full file visible
    @State private var windowStart:  Double = 0.0   // file-fraction of left edge
    @State private var pinchBase:    Double? = nil   // zoom level captured at pinch start

    // Selection drag
    @State private var dragStart: Double? = nil

    // MARK: - Zoom geometry

    private var windowSize: Double { 1.0 / max(zoomLevel, 1.0) }
    private var windowEnd:  Double { min(windowStart + windowSize, 1.0) }

    /// File fraction → view fraction (may be outside 0…1 when off-screen)
    private func toViewFrac(_ f: Double) -> Double { (f - windowStart) / windowSize }

    /// View fraction → file fraction (clamped to 0…1)
    private func toFileFrac(_ v: Double) -> Double {
        min(max(windowStart + v * windowSize, 0), 1)
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {

                // ── Waveform canvas ──────────────────────────────────────────
                Canvas { ctx, size in
                    guard !peaks.isEmpty, let first = peaks.first, !first.isEmpty else { return }
                    let n            = first.count
                    let startIdx     = max(0, Int(windowStart * Double(n)))
                    let endIdx       = min(n, max(startIdx + 1, Int(windowEnd * Double(n))))
                    let visibleCount = endIdx - startIdx
                    guard visibleCount > 0 else { return }

                    let channelCount = peaks.count
                    let bandHeight   = size.height / CGFloat(channelCount)

                    // When peaks outnumber drawable columns, aggregate into pixel-wide buckets.
                    let pixelCols = max(1, Int(size.width))
                    let stride    = max(1, visibleCount / pixelCols)
                    let drawCount = (visibleCount + stride - 1) / stride
                    let step      = size.width / CGFloat(drawCount)

                    for (ch, channelPeaks) in peaks.enumerated() {
                        let midY = bandHeight * CGFloat(ch) + bandHeight / 2
                        var path = Path()
                        for col in 0..<drawCount {
                            let iStart = startIdx + col * stride
                            let iEnd   = min(startIdx + (col + 1) * stride, endIdx)
                            var colMax: Float = 0
                            for i in iStart..<iEnd { colMax = max(colMax, channelPeaks[i]) }
                            let x   = CGFloat(col) * step + step / 2
                            let amp = min(CGFloat(colMax) * CGFloat(player.volume), 1.0)
                                        * (bandHeight / 2) * 0.9
                            path.move(to:    CGPoint(x: x, y: midY - amp))
                            path.addLine(to: CGPoint(x: x, y: midY + amp))
                        }
                        ctx.stroke(path, with: .color(waveColor.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: max(1, step * 0.6)))
                    }

                    if channelCount > 1 {
                        var div = Path()
                        for ch in 1..<channelCount {
                            let y = bandHeight * CGFloat(ch)
                            div.move(to:    CGPoint(x: 0,          y: y))
                            div.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        ctx.stroke(div, with: .color(.white.opacity(0.15)),
                                   style: StrokeStyle(lineWidth: 0.5))
                    }
                }
                .background(waveBackground)
                .cornerRadius(4)

                // ── Selection region ─────────────────────────────────────────
                if let selStart = player.selectionStart,
                   let selEnd   = player.selectionEnd, selEnd > selStart {
                    let w  = geo.size.width
                    let vS = toViewFrac(selStart)
                    let vE = toViewFrac(selEnd)
                    if vE > 0 && vS < 1 {
                        let cS = max(0, vS)
                        let cE = min(1, vE)
                        Rectangle()
                            .fill(waveColor.opacity(0.25))
                            .frame(width: w * CGFloat(cE - cS))
                            .offset(x:    w * CGFloat(cS))
                        Rectangle()
                            .fill(waveColor)
                            .frame(width: 2)
                            .offset(x: w * CGFloat(cS))
                        Rectangle()
                            .fill(waveColor)
                            .frame(width: 2)
                            .offset(x: w * CGFloat(cE) - 2)
                    }
                }

                // ── Played portion ───────────────────────────────────────────
                let vPlay = toViewFrac(player.playPosition)
                if vPlay > 0 {
                    Rectangle()
                        .fill(waveColor.opacity(0.15))
                        .frame(width: geo.size.width * CGFloat(min(1, vPlay)))
                }

                // ── Playhead ─────────────────────────────────────────────────
                if vPlay >= 0 && vPlay <= 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * CGFloat(vPlay) - 0.75)
                }

                // ── Zoom level badge — tap to reset ──────────────────────────
                if zoomLevel > 1.01 {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    zoomLevel   = 1.0
                                    windowStart = 0.0
                                }
                            } label: {
                                Text(zoomLevel < 10
                                     ? String(format: "%.1f×", zoomLevel)
                                     : String(format: "%.0f×", zoomLevel))
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.80))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(Color.black.opacity(0.55))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .help("Zoom: \(String(format: "%.1f", zoomLevel))× — click to reset")
                            .padding(5)
                        }
                        Spacer()
                    }
                }
            }
            .contentShape(Rectangle())

            // ── Scroll wheel / trackpad swipe ────────────────────────────────
            .overlay(
                ScrollWheelReceiver { deltaX, deltaY, locFrac in
                    if abs(deltaY) >= abs(deltaX) {
                        // Vertical: zoom in/out, anchored under cursor
                        let factor = exp(-Double(deltaY) * 0.022)
                        zoom(by: factor, anchorViewFrac: locFrac)
                    } else {
                        // Horizontal: pan
                        let fileDelta = Double(deltaX) / Double(geo.size.width) * windowSize
                        pan(by: fileDelta)
                    }
                }
            )

            // ── Pinch to zoom ────────────────────────────────────────────────
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        if pinchBase == nil { pinchBase = zoomLevel }
                        let target = (pinchBase ?? zoomLevel) * Double(value)
                        zoom(to: target, anchorViewFrac: 0.5)
                    }
                    .onEnded { _ in pinchBase = nil }
            )

            // ── Selection drag / seek ────────────────────────────────────────
            .simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { val in
                        let w    = geo.size.width
                        let frac = toFileFrac(val.location.x / w)
                        if dragStart == nil {
                            dragStart = toFileFrac(val.startLocation.x / w)
                        }
                        guard let start = dragStart else { return }
                        if frac >= start {
                            player.selectionStart = start
                            player.selectionEnd   = frac
                        } else {
                            player.selectionStart = frac
                            player.selectionEnd   = start
                        }
                    }
                    .onEnded { val in
                        let w    = geo.size.width
                        let frac = toFileFrac(val.location.x / w)
                        guard let start = dragStart else { return }
                        dragStart = nil
                        if abs(val.location.x - val.startLocation.x) < 4 {
                            player.selectionStart = nil
                            player.selectionEnd   = nil
                            player.seek(to: frac)
                            if playOnClick && !player.isPlaying { player.play() }
                        }
                    }
            )

            // ── Double-click to reset zoom ────────────────────────────────────
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.18)) {
                    zoomLevel   = 1.0
                    windowStart = 0.0
                }
            }
            .onTapGesture { location in
                player.selectionStart = nil
                player.selectionEnd   = nil
                player.seek(to: toFileFrac(location.x / geo.size.width))
                if playOnClick && !player.isPlaying { player.play() }
            }

            .onAppear { loadPeaks(width: max(Int(geo.size.width) * 8, 4096)) }
            .onChange(of: url) { _, _ in
                zoomLevel   = 1.0
                windowStart = 0.0
                loadPeaks(width: max(Int(geo.size.width) * 8, 4096))
            }
        }
    }

    // MARK: - Zoom / pan

    private func zoom(by factor: Double, anchorViewFrac: Double) {
        zoom(to: zoomLevel * factor, anchorViewFrac: anchorViewFrac)
    }

    private func zoom(to newZoom: Double, anchorViewFrac: Double) {
        let clamped       = max(1.0, min(newZoom, 500.0))
        let newWindowSize = 1.0 / clamped
        // Use unclamped anchor so the point under the cursor stays fixed
        let anchorFile    = windowStart + anchorViewFrac * windowSize
        let newStart      = anchorFile - anchorViewFrac * newWindowSize
        windowStart = max(0, min(newStart, 1.0 - newWindowSize))
        zoomLevel   = clamped
    }

    private func pan(by fileDelta: Double) {
        windowStart = max(0, min(windowStart + fileDelta, 1.0 - windowSize))
    }

    // MARK: - Peak loading

    private func loadPeaks(width: Int) {
        let targetURL   = url
        let targetMtime = mtime
        if let cached = ThumbnailCache.shared.get(url: targetURL.path, mtime: targetMtime, width: width) {
            peaks = cached
            return
        }
        Task.detached(priority: .userInitiated) {
            guard let generated = try? await WaveformGenerator.peaks(for: targetURL,
                                                                      targetSamples: width)
            else { return }
            ThumbnailCache.shared.set(peaks: generated, url: targetURL.path,
                                      mtime: targetMtime, width: width)
            await MainActor.run { peaks = generated }
        }
    }
}

// MARK: - Scroll wheel capture (AppKit bridge)

private struct ScrollWheelReceiver: NSViewRepresentable {
    /// Callback: (deltaX, deltaY, locationFrac 0…1 in view width)
    let onScroll: (CGFloat, CGFloat, Double) -> Void

    func makeNSView(context: Context) -> WheelView { WheelView(onScroll: onScroll) }
    func updateNSView(_ v: WheelView, context: Context) { v.onScroll = onScroll }

    final class WheelView: NSView {
        var onScroll: (CGFloat, CGFloat, Double) -> Void
        init(onScroll: @escaping (CGFloat, CGFloat, Double) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func scrollWheel(with event: NSEvent) {
            let loc  = convert(event.locationInWindow, from: nil)
            let frac = bounds.width > 0 ? Double(loc.x / bounds.width) : 0.5
            onScroll(event.scrollingDeltaX, event.scrollingDeltaY, frac)
        }
    }
}
