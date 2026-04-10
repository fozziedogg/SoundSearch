import SwiftUI

struct DetailView: View {
    @Environment(AppEnvironment.self) var env
    let file: AudioFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fixed top section — must NOT be inside a ScrollView or the
            // NSView-based drag bar loses its mouseDragged events to SwiftUI's
            // scroll gesture recognizers.
            WaveformView(url: URL(fileURLWithPath: file.fileURL),
                         mtime: file.mtime,
                         playOnClick: env.playOnWaveformClick)
                .environmentObject(env.audioPlayer)
                .frame(height: 80)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .id(file.id)

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

            PitchControlView()
                .environmentObject(env.audioPlayer)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider()

            // Scrollable metadata section
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    MetadataFormView(file: file)
                        .padding(16)

                    Divider()

                    TechnicalInfoView(file: file)
                        .padding(16)

                    Divider()

                    ProToolsSpotView(file: file)
                        .environmentObject(env.audioPlayer)
                        .padding(16)
                }
            }
        }
        .onAppear {
            env.audioPlayer.load(url: URL(fileURLWithPath: file.fileURL))
            if env.autoPlayOnSelect { env.audioPlayer.play() }
        }
        .onChange(of: file.fileURL) { _, newURL in
            env.audioPlayer.load(url: URL(fileURLWithPath: newURL))
            if env.autoPlayOnSelect { env.audioPlayer.play() }
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
