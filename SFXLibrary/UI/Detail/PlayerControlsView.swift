import SwiftUI
import AppKit

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

            // Volume row  (slider goes to 200% — above 100% boosts beyond unity)
            HStack(spacing: 8) {
                Image(systemName: player.volume < 0.01 ? "speaker.slash" :
                                  player.volume < 0.4  ? "speaker.wave.1" :
                                  player.volume < 0.75 ? "speaker.wave.2" : "speaker.wave.3")
                    .font(.system(size: 11))
                    .foregroundColor(player.volume > 1.0 ? .orange : .secondary)
                    .frame(width: 16)
                VolumeSlider(value: $player.volume, range: 0...2) {
                    player.volume = 1.0
                }
                .help("Double-click to reset to unity")
                Text(String(format: "%d%%", Int(player.volume * 100)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(player.volume > 1.0 ? .orange : .secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            // Playback options row
            HStack(spacing: 2) {
                Spacer()
                optionToggle(
                    icon: "bolt", activeIcon: "bolt.fill",
                    label: "Autoplay",
                    help: "Play automatically when a file is selected",
                    isOn: env.autoPlayOnSelect
                ) { env.autoPlayOnSelect.toggle() }

                optionToggle(
                    icon: "cursorarrow.rays",
                    label: "Click to Play",
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
    private func optionToggle(icon: String, activeIcon: String? = nil, label: String, help: String,
                               isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: isOn ? (activeIcon ?? icon) : icon)
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

// MARK: - Volume slider (NSSlider subclass to catch double-click)

private struct VolumeSlider: NSViewRepresentable {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DoubleClickSlider {
        let slider = DoubleClickSlider()
        slider.minValue     = Double(range.lowerBound)
        slider.maxValue     = Double(range.upperBound)
        slider.floatValue   = value
        slider.onDoubleClick = onDoubleClick
        slider.target       = context.coordinator
        slider.action       = #selector(Coordinator.valueChanged(_:))
        return slider
    }

    func updateNSView(_ nsView: DoubleClickSlider, context: Context) {
        // Only push from binding → view when the value actually differs,
        // to avoid fighting with live drag updates.
        if abs(nsView.floatValue - value) > 0.001 {
            nsView.floatValue = value
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: VolumeSlider
        init(_ parent: VolumeSlider) { self.parent = parent }
        @objc func valueChanged(_ sender: NSSlider) { parent.value = sender.floatValue }
    }

    /// NSSlider subclass that fires a callback on double-click while letting
    /// single-clicks through to normal slider tracking.
    final class DoubleClickSlider: NSSlider {
        var onDoubleClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick?()
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}
