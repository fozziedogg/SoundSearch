import SwiftUI

struct DetailView: View {
    @Environment(AppEnvironment.self) var env
    let file: AudioFile

    @State private var selectionStart: Double? = nil
    @State private var selectionEnd:   Double? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Waveform + player
                WaveformView(url: URL(fileURLWithPath: file.fileURL),
                             mtime: file.mtime,
                             selectionStart: $selectionStart,
                             selectionEnd:   $selectionEnd)
                    .environmentObject(env.audioPlayer)
                    .frame(height: 80)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                PlayerControlsView()
                    .environmentObject(env.audioPlayer)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                PitchControlView()
                    .environmentObject(env.audioPlayer)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                Divider()

                // Metadata form
                MetadataFormView(file: file)
                    .padding(16)

                Divider()

                // Technical info (read-only)
                TechnicalInfoView(file: file)
                    .padding(16)

                Divider()

                // ProTools spot
                ProToolsSpotView(file: file,
                                 selectionStart: selectionStart,
                                 selectionEnd:   selectionEnd)
                    .padding(16)
            }
        }
        .onAppear {
            env.audioPlayer.load(url: URL(fileURLWithPath: file.fileURL))
        }
        .onChange(of: file.id) { _ in
            selectionStart = nil
            selectionEnd   = nil
            env.audioPlayer.load(url: URL(fileURLWithPath: file.fileURL))
        }
    }
}

// MARK: - Technical info

private struct TechnicalInfoView: View {
    let file: AudioFile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Technical")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(1)
                .padding(.bottom, 4)

            HStack(spacing: 16) {
                if let sr = file.sampleRate { chip("\(sr / 1000) kHz") }
                if let bd = file.bitDepth   { chip("\(bd)-bit") }
                if let ch = file.channels   { chip(ch == 1 ? "Mono" : ch == 2 ? "Stereo" : "\(ch)ch") }
                if let lu = file.lufs       { chip(String(format: "%.1f LUFS", lu)) }
                if let d  = file.duration   { chip(String(format: "%.2fs", d)) }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
    }
}
