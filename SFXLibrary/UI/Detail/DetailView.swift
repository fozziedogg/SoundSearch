import SwiftUI
import AppKit

// MARK: - Preview panel (waveform + playback controls)

struct PreviewView: View {
    @Environment(AppEnvironment.self) var env
    let file: AudioFile

    @State private var waveformHeight: CGFloat = 80
    @State private var fileNotFound: Bool = false

    // Fixed chrome below the waveform: resize handle (8) + drag bar (30) + controls (~62) + header (22)
    private let waveformChrome: CGFloat = 122

    var body: some View {
        GeometryReader { geo in
            // Cap the displayed waveform height so it never pushes content above the pane top.
            let clampedWH = min(waveformHeight, max(40, geo.size.height - waveformChrome))
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader(title: "Preview")

                WaveformView(url: URL(fileURLWithPath: file.fileURL),
                             mtime: file.mtime,
                             playOnClick: env.playOnWaveformClick,
                             waveColor: env.waveformColor)
                    .environmentObject(env.audioPlayer)
                    .frame(height: clampedWH)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .id(file.id)

                WaveformResizeHandle(height: $waveformHeight)
                    .padding(.horizontal, 16)

                WaveformDragBar(file: file)
                    .environmentObject(env.audioPlayer)
                    .frame(height: 26)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                PlayerControlsView()
                    .environmentObject(env.audioPlayer)
                    .environment(env)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .padding(.bottom, 4)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        }
        .onAppear {
            if FileManager.default.fileExists(atPath: file.fileURL) {
                env.audioPlayer.load(url: URL(fileURLWithPath: file.fileURL))
                if env.autoPlayOnSelect { env.audioPlayer.play() }
            } else {
                flagMissing()
            }
        }
        .onChange(of: file.fileURL) { _, newURL in
            if FileManager.default.fileExists(atPath: newURL) {
                env.audioPlayer.load(url: URL(fileURLWithPath: newURL))
                if env.autoPlayOnSelect { env.audioPlayer.play() }
            } else {
                flagMissing()
            }
        }
        .alert("File Not Found", isPresented: $fileNotFound) {
            Button("Open Parent Folder") {
                let parent = URL(fileURLWithPath: file.fileURL).deletingLastPathComponent()
                NSWorkspace.shared.open(parent)
            }
            if let watchedPath = env.watchedFolders
                .first(where: { file.fileURL.hasPrefix($0.path) })?.path {
                Button("Rescan Folder") {
                    env.rescanFolder(path: watchedPath)
                }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text("\"\(file.filename)\" could not be found at its recorded location. The file may have been moved or deleted.")
        }
    }

    private func flagMissing() {
        fileNotFound = true
        if let watchedPath = env.watchedFolders
            .first(where: { file.fileURL.hasPrefix($0.path) })?.path,
           !env.foldersWithChanges.contains(watchedPath) {
            env.foldersWithChanges.append(watchedPath)
        }
    }
}

// MARK: - File Info panel (metadata + technical + Pro Tools spot)

struct FileInfoView: View {
    @Environment(AppEnvironment.self) var env
    let file: AudioFile
    @Binding var isExpanded: Bool
    /// Called with the cumulative drag delta (positive = drag down) so the parent can resize.
    var onHeaderDrag: ((CGFloat) -> Void)? = nil

    @State private var prevDragTranslation: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header with expand/collapse toggle — also acts as resize drag handle
            HStack {
                Text("File Info")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(1.5)
                Spacer()
                if onHeaderDrag != nil {
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.4))
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide File Info" : "Show File Info")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.25))
            .onHover { hovering in
                guard onHeaderDrag != nil else { return }
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { val in
                        guard let onHeaderDrag else { return }
                        let delta = val.translation.height - prevDragTranslation
                        prevDragTranslation = val.translation.height
                        onHeaderDrag(delta)
                    }
                    .onEnded { _ in prevDragTranslation = 0 }
            )

            if isExpanded {
                Divider()
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        TechnicalInfoView(file: file)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)

                        Divider()

                        MetadataFormView(file: file)
                            .padding(12)
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

// MARK: - Shared panel header

struct PanelHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(1.5)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.25))
    }
}

// MARK: - Waveform resize handle

private struct WaveformResizeHandle: View {
    @Binding var height: CGFloat
    @State private var isHovering = false
    @State private var dragBase: CGFloat = 0

    private let minHeight: CGFloat = 40
    private let maxHeight: CGFloat = 400

    var body: some View {
        ZStack {
            // Hit area (taller than the visible line for easier grabbing)
            Color.clear
                .frame(height: 8)
                .contentShape(Rectangle())

            // Visual indicator
            RoundedRectangle(cornerRadius: 1)
                .fill(isHovering ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.12))
                .frame(width: 32, height: 2)
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { val in
                    if val.translation.height == val.predictedEndTranslation.height
                        && dragBase == 0 {
                        dragBase = height
                    }
                    if dragBase == 0 { dragBase = height }
                    let proposed = dragBase + val.translation.height
                    height = min(max(proposed, minHeight), maxHeight)
                }
                .onEnded { _ in dragBase = 0 }
        )
    }
}

// MARK: - Technical info

private struct TechnicalInfoView: View {
    let file: AudioFile

    var body: some View {
        HStack(spacing: 6) {
            if let sr = file.sampleRate { chip("\(sr / 1000) kHz") }
            if let bd = file.bitDepth   { chip("\(bd)-bit") }
            if let ch = file.channels   { chip(ch == 1 ? "Mono" : ch == 2 ? "Stereo" : "\(ch)ch") }
            if let d  = file.duration   { chip(String(format: "%.2fs", d)) }
            if let lu = file.lufs       { chip(String(format: "%.1f LUFS", lu)) }
            Spacer()
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
