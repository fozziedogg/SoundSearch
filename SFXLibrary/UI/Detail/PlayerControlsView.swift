import SwiftUI

struct PlayerControlsView: View {
    @EnvironmentObject var player: AudioPlayer
    @Environment(AppEnvironment.self) var env

    var body: some View {
        VStack(spacing: 4) {
            // Transport row
            HStack(spacing: 16) {
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "stop.fill" : "play.fill")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                Text(formatTime(player.duration * player.playPosition))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .leading)

                Spacer()

                Text(formatTime(player.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }

            // Playback options row
            HStack(spacing: 2) {
                Spacer()
                optionToggle(
                    icon: "bolt",
                    label: "Autoplay",
                    help: "Play automatically when a file is selected",
                    isOn: env.autoPlayOnSelect
                ) { env.autoPlayOnSelect.toggle() }

                optionToggle(
                    icon: "cursorarrow.rays",
                    label: "Click",
                    help: "Play when clicking on the waveform",
                    isOn: env.playOnWaveformClick
                ) { env.playOnWaveformClick.toggle() }

                optionToggle(
                    icon: "repeat",
                    label: "Loop",
                    help: "Loop the selection during playback",
                    isOn: player.loopEnabled
                ) { player.loopEnabled.toggle() }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func optionToggle(icon: String, label: String, help: String,
                               isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: isOn ? "\(icon).fill" : icon)
                Text(label)
            }
            .font(.system(size: 10))
            .foregroundColor(isOn ? .accentColor : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isOn ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func formatTime(_ seconds: Double) -> String {
        let s  = Int(seconds)
        let ms = Int((seconds - Double(s)) * 1000)
        let m  = s / 60
        let se = s % 60
        return String(format: "%d:%02d.%03d", m, se, ms)
    }
}
