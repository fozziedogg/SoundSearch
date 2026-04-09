import SwiftUI

struct PlayerControlsView: View {
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
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
    }

    private func formatTime(_ seconds: Double) -> String {
        let s  = Int(seconds)
        let ms = Int((seconds - Double(s)) * 1000)
        let m  = s / 60
        let se = s % 60
        return String(format: "%d:%02d.%03d", m, se, ms)
    }
}
