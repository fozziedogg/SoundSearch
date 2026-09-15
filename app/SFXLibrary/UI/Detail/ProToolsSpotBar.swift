import SwiftUI
import AppKit

struct ProToolsSpotBar: View {
    let file: AudioFile
    @EnvironmentObject var player: AudioPlayer
    @Environment(AppEnvironment.self) var env

    @State private var isWorking = false
    @State private var workLabel = ""

    var body: some View {
        HStack(spacing: 6) {
            if isWorking {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(workLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            } else {
                Button("Spot to PT") { Task { await doSpotContent() } }
                    .buttonStyle(PTSpotButtonStyle())
            }
        }
        .onChange(of: file.id) { _, _ in env.spotFeedback = nil }
    }

    // MARK: - Actions

    private func doSpotContent() async {
        guard let sampleRate = file.sampleRate, let duration = file.duration else {
            env.spotFeedback = .failure("Missing file metadata"); return
        }
        player.stop()
        begin("Spotting…")

        var spotURL = URL(fileURLWithPath: file.fileURL)
        let gain = player.volume
        if env.commitVolumeOnExport, abs(gain - 1.0) > 0.001,
           let gained = try? DragBarHelper.applyGain(to: spotURL, gain: gain) {
            spotURL = gained
        }

        // Source in/out (samples) — the AppleEvent trims the region inside Pro
        // Tools, so no temp-file selection export is needed.
        let sr = Double(sampleRate)
        let srcStart = Int32(clamping: Int64(((player.selectionStart ?? 0.0) * duration * sr).rounded()))
        let srcStop  = Int32(clamping: Int64(((player.selectionEnd   ?? 1.0) * duration * sr).rounded()))
        let name = spotURL.deletingPathExtension().lastPathComponent

        await run {
            try await ProToolsSpotter.spot(fileURL: spotURL,
                                           srcStartSample: srcStart,
                                           srcStopSample: srcStop,
                                           name: name)
        }
    }

    // MARK: - Helpers

    private func begin(_ label: String) {
        isWorking        = true
        workLabel        = label
        env.spotFeedback = nil
    }

    private func run(_ block: @escaping () async throws -> Void) async {
        do {
            try await block()
            env.spotFeedback = .success
            env.addToActiveProject(fileURL: file.fileURL)
            if env.focusProToolsOnSpot {
                NSWorkspace.shared.runningApplications
                    .first { $0.bundleIdentifier == "com.avid.ProTools"
                          || $0.localizedName    == "Pro Tools" }?
                    .activate(options: .activateIgnoringOtherApps)
            }
            // No engine rebuild here — rebuilding while PT's audio device is still hot
            // from the import causes a startup transient on a stressed device and leaves
            // the audio path glitchy. The AVAudioEngineConfigurationChange handler
            // already handles any real device reconfiguration PT triggers.
        } catch {
            env.spotFeedback = .failure(error.localizedDescription)
        }
        isWorking = false
    }
}

// MARK: - Button style

private struct PTSpotButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.18 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
    }
}
