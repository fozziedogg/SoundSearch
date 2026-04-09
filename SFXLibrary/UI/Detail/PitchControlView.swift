import SwiftUI

struct PitchControlView: View {
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            VStack(spacing: 4) {
                HStack {
                    Text("Semitones")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 68, alignment: .leading)
                    Slider(value: $player.pitchSemitones, in: -12...12, step: 1)
                        .onChange(of: player.pitchSemitones) { _ in applyPitch() }
                    Text(String(format: "%+.0f", player.pitchSemitones))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                HStack {
                    Text("Cents")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 68, alignment: .leading)
                    Slider(value: $player.pitchCents, in: -100...100, step: 1)
                        .onChange(of: player.pitchCents) { _ in applyPitch() }
                    Text(String(format: "%+.0f", player.pitchCents))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }

            Button("Reset") {
                player.resetPitch()
            }
            .font(.system(size: 10))
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
    }

    private func applyPitch() {
        player.setPitch(semitones: player.pitchSemitones, cents: player.pitchCents)
    }
}
